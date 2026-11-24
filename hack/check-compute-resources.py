#!/usr/bin/env python3
"""Check the computeResources blocks of the Tekton task definitions.

The rules enforced here are documented, together with the sizing rationale
for every value, in docs/compute-resources.md:

1. every step declares both a ``requests`` and a ``limits`` section;
2. ``requests.memory`` is declared together with ``limits.memory`` and is
   not greater than it;
3. a step that declares ``requests.cpu`` also declares ``limits.cpu``, and
   the limit is not lower than the request, unless the omission is recorded
   with a ``# resource-check: no-cpu-limit <reason>`` comment next to the
   step's ``computeResources`` block;
4. steps shared by both task flavors declare the same computeResources.

Run by pre-commit (see .pre-commit-config.yaml) and callable by hand:

    ./hack/check-compute-resources.py [TASK_YAML ...]

With no arguments every ``task/*/*.yaml`` file is checked.
"""

from __future__ import annotations

import re
import sys
from decimal import Decimal, InvalidOperation
from fractions import Fraction
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
TASK_GLOB = "task/*/*.yaml"

# An intentionally absent CPU limit is recorded with a comment such as:
#   # resource-check: no-cpu-limit - relies on the namespace LimitRange, see <link>
OPT_OUT_RE = re.compile(r"#\s*resource-check:\s*no-cpu-limit\b[\s:,.=-]*(?P<reason>.*?)\s*$")
# A bare marker is not a record of anything, so require a few words of reason.
MIN_REASON_LENGTH = 15
# How many lines above the `computeResources:` key the marker may be placed.
OPT_OUT_LOOKBEHIND = 2

# Kubernetes quantity suffixes: decimal SI, binary SI and the milli unit.
MULTIPLIERS = {
    "": Fraction(1),
    "m": Fraction(1, 1000),
    "k": Fraction(10**3),
    "M": Fraction(10**6),
    "G": Fraction(10**9),
    "T": Fraction(10**12),
    "P": Fraction(10**15),
    "E": Fraction(10**18),
    "Ki": Fraction(2**10),
    "Mi": Fraction(2**20),
    "Gi": Fraction(2**30),
    "Ti": Fraction(2**40),
    "Pi": Fraction(2**50),
    "Ei": Fraction(2**60),
}
QUANTITY_RE = re.compile(r"^(?P<value>[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)(?P<suffix>[A-Za-z]*)$")

RESOURCE_SECTIONS = ("requests", "limits")
RESOURCE_NAMES = ("cpu", "memory")


class CheckError(Exception):
    """A task file that cannot be inspected at all."""


def parse_quantity(raw):
    """Return a Kubernetes quantity as an exact Fraction."""
    text = str(raw).strip()
    match = QUANTITY_RE.match(text)
    if match is None:
        raise ValueError(f"{text!r} is not a Kubernetes quantity")
    suffix = match.group("suffix")
    if suffix not in MULTIPLIERS:
        raise ValueError(f"{text!r} has an unknown unit {suffix!r}")
    try:
        value = Fraction(Decimal(match.group("value")))
    except InvalidOperation as exc:  # pragma: no cover - guarded by the regex
        raise ValueError(f"{text!r} is not a Kubernetes quantity") from exc
    return value * MULTIPLIERS[suffix]


def mapping_entry(node, key):
    """Return the (key node, value node) pair of a mapping node, or (None, None)."""
    if not isinstance(node, yaml.MappingNode):
        return None, None
    for key_node, value_node in node.value:
        if isinstance(key_node, yaml.ScalarNode) and key_node.value == key:
            return key_node, value_node
    return None, None


class Step:
    """One step of a Tekton task, with the source locations we report on."""

    def __init__(self, path, name, line):
        self.path = path
        self.name = name
        self.line = line
        self.compute_line = line
        # section -> resource name -> raw value as written in the YAML
        self.declared = {section: {} for section in RESOURCE_SECTIONS}
        self.has_section = dict.fromkeys(RESOURCE_SECTIONS, False)
        self.has_compute_resources = False
        self.opt_out_reason = None
        self.has_opt_out_marker = False

    def where(self, line=None):
        return f"{self.path}:{line or self.compute_line}"


def read_section(section_node):
    """Return {resource name: raw value} for a requests/limits mapping node."""
    declared = {}
    if not isinstance(section_node, yaml.MappingNode):
        return declared
    for key_node, value_node in section_node.value:
        if isinstance(key_node, yaml.ScalarNode) and isinstance(value_node, yaml.ScalarNode):
            declared[key_node.value] = value_node.value
    return declared


def find_opt_out(lines, first_line, last_line):
    """Return (marker found, reason) for the opt-out comment in a line window."""
    start = max(0, first_line - OPT_OUT_LOOKBEHIND)
    end = min(len(lines), last_line + 1)
    for line in lines[start:end]:
        match = OPT_OUT_RE.search(line)
        if match is not None:
            return True, match.group("reason").strip()
    return False, None


def load_steps(path):
    """Parse a task file and return its steps."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    try:
        root = yaml.compose(text)
    except yaml.YAMLError as exc:
        raise CheckError(f"{path}: cannot parse YAML: {exc}") from exc
    if root is None:
        raise CheckError(f"{path}: file is empty")

    _, kind_node = mapping_entry(root, "kind")
    if kind_node is None or kind_node.value != "Task":
        return []

    _, spec_node = mapping_entry(root, "spec")
    _, steps_node = mapping_entry(spec_node, "steps") if spec_node is not None else (None, None)
    if not isinstance(steps_node, yaml.SequenceNode) or not steps_node.value:
        raise CheckError(f"{path}: task declares no steps")

    steps = []
    for step_node in steps_node.value:
        _, name_node = mapping_entry(step_node, "name")
        name = name_node.value if name_node is not None else "<unnamed>"
        step = Step(path, name, step_node.start_mark.line + 1)

        compute_key, compute_node = mapping_entry(step_node, "computeResources")
        if compute_node is not None:
            step.has_compute_resources = True
            step.compute_line = compute_key.start_mark.line + 1
            for section in RESOURCE_SECTIONS:
                _, section_node = mapping_entry(compute_node, section)
                if section_node is not None:
                    step.has_section[section] = True
                    step.declared[section] = read_section(section_node)
            step.has_opt_out_marker, step.opt_out_reason = find_opt_out(
                lines, compute_key.start_mark.line, compute_node.end_mark.line
            )
        steps.append(step)
    return steps


def quantities(step, errors):
    """Return the parsed quantities of a step, reporting unparsable values."""
    parsed = {section: {} for section in RESOURCE_SECTIONS}
    for section in RESOURCE_SECTIONS:
        for name, raw in step.declared[section].items():
            if name not in RESOURCE_NAMES:
                continue
            try:
                parsed[section][name] = parse_quantity(raw)
            except ValueError as exc:
                errors.append(f"{step.where()}: step {step.name!r}: {section}.{name}: {exc}")
                parsed[section][name] = None
    return parsed


def check_step(step, errors):
    """Apply the per-step rules. Returns the parsed quantities, or None."""
    if not step.has_compute_resources:
        errors.append(
            f"{step.where(step.line)}: step {step.name!r}: no computeResources block; "
            f"every step must declare requests and limits"
        )
        return None

    for section in RESOURCE_SECTIONS:
        if not step.declared[section]:
            errors.append(
                f"{step.where()}: step {step.name!r}: computeResources.{section} is missing or empty"
            )

    parsed = quantities(step, errors)
    requests, limits = parsed["requests"], parsed["limits"]

    if "memory" in requests:
        if "memory" not in limits:
            errors.append(
                f"{step.where()}: step {step.name!r}: requests.memory is declared but "
                f"limits.memory is missing"
            )
        elif None not in (requests["memory"], limits["memory"]) and requests["memory"] > limits["memory"]:
            errors.append(
                f"{step.where()}: step {step.name!r}: requests.memory "
                f"({step.declared['requests']['memory']}) is greater than limits.memory "
                f"({step.declared['limits']['memory']})"
            )

    if "cpu" in requests:
        if "cpu" not in limits:
            if not step.has_opt_out_marker:
                errors.append(
                    f"{step.where()}: step {step.name!r}: requests.cpu "
                    f"({step.declared['requests']['cpu']}) is declared with no limits.cpu; "
                    f"add limits.cpu, or record why it is absent with a comment "
                    f"'# resource-check: no-cpu-limit - <reason>' next to the "
                    f"computeResources block (see docs/compute-resources.md)"
                )
            elif len(step.opt_out_reason or "") < MIN_REASON_LENGTH:
                errors.append(
                    f"{step.where()}: step {step.name!r}: the no-cpu-limit opt-out comment "
                    f"must record why the limit is absent, on the same line as the marker"
                )
        elif None not in (requests["cpu"], limits["cpu"]) and requests["cpu"] > limits["cpu"]:
            errors.append(
                f"{step.where()}: step {step.name!r}: requests.cpu "
                f"({step.declared['requests']['cpu']}) is greater than limits.cpu "
                f"({step.declared['limits']['cpu']})"
            )

    if step.has_opt_out_marker and "cpu" in limits:
        errors.append(
            f"{step.where()}: step {step.name!r}: a no-cpu-limit opt-out comment is recorded "
            f"but limits.cpu is declared; remove the stale comment"
        )

    return parsed


def check_shared_steps(steps_by_file, parsed_by_step, errors):
    """Steps that appear in more than one flavor must size identically."""
    by_name = {}
    for path, steps in steps_by_file.items():
        for step in steps:
            by_name.setdefault(step.name, []).append(step)

    for name, steps in sorted(by_name.items()):
        if len(steps) < 2:
            continue
        reference = steps[0]
        for step in steps[1:]:
            if parsed_by_step.get(id(reference)) is None or parsed_by_step.get(id(step)) is None:
                continue
            if parsed_by_step[id(reference)] != parsed_by_step[id(step)]:
                errors.append(
                    f"{step.where()}: step {name!r}: computeResources differ from "
                    f"{reference.where()}; steps shared by both task flavors must be "
                    f"kept in sync"
                )


def display_path(path):
    """Prefer a path relative to the working directory in the output."""
    try:
        return path.relative_to(Path.cwd())
    except ValueError:
        return path


def task_files(argv):
    if argv:
        return [Path(arg) for arg in argv]
    return [display_path(path) for path in sorted(REPO_ROOT.glob(TASK_GLOB))]


def main(argv):
    paths = task_files(argv)
    if not paths:
        print("no task files found", file=sys.stderr)
        return 1

    errors = []
    steps_by_file = {}
    parsed_by_step = {}
    for path in paths:
        try:
            steps = load_steps(path)
        except CheckError as exc:
            errors.append(str(exc))
            continue
        steps_by_file[path] = steps
        for step in steps:
            parsed_by_step[id(step)] = check_step(step, errors)

    check_shared_steps(steps_by_file, parsed_by_step, errors)

    if errors:
        print("computeResources check failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    checked = sum(len(steps) for steps in steps_by_file.values())
    print(f"computeResources check passed: {checked} steps in {len(steps_by_file)} task files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

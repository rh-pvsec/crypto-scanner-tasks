#!/usr/bin/env bash
#
# Offline regression tests for the `pull-rules` step of both crypto scan task
# flavours.
#
# Unlike test-pipeline.sh, this needs no cluster: it extracts the real step
# script out of each task YAML, substitutes the Tekton placeholders with
# temporary directories, and runs it against a stub `oc`. It asserts the
# warning-marker contract that the rh-crypto-scanner step consumes, and that
# the two flavours have not drifted apart.
#
# Usage: ./hack/test-pull-rules.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-pull-rules.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

NON_TA_YAML="${REPO_ROOT}/task/sast-crypto-scan/sast-crypto-scan.yaml"
NON_TA_NAME="sast-crypto-scan"
TA_YAML="${REPO_ROOT}/task/sast-crypto-scan-oci-ta/sast-crypto-scan-oci-ta.yaml"
TA_NAME="sast-crypto-scan-oci-ta"

PASSES=0
FAILURES=0

# --- helpers ---------------------------------------------------------------

# extract_step <task-yaml> <step-name> <out-file> <workspace-dir> <workdir> <task-name>
extract_step() {
  python3 - "$@" <<'PY'
import sys

import yaml

task_yaml, step_name, out_file, workspace_dir, workdir, task_name = sys.argv[1:7]

with open(task_yaml) as handle:
    doc = yaml.safe_load(handle)

for step in doc["spec"]["steps"]:
    if step["name"] == step_name:
        script = step["script"]
        break
else:
    sys.exit(f"step {step_name} not found in {task_yaml}")

# Tekton variable substitution, plus the absolute /var/workdir path the
# Trusted Artifacts flavour uses, redirected into the test sandbox.
script = script.replace("$(workspaces.workspace.path)", workspace_dir)
script = script.replace("$(context.task.name)", task_name)
script = script.replace("/var/workdir", workdir)

with open(out_file, "w") as handle:
    handle.write(script)
PY
}

make_stub_oc() {
  mkdir -p "${TMPROOT}/bin"
  cat > "${TMPROOT}/bin/oc" <<'STUB'
#!/usr/bin/env bash
# Stub `oc` driven by environment variables. Emulates the parts of
# `oc get configmap -o jsonpath=...` the pull-rules step depends on.
set -uo pipefail

ARGS="$*"

if [[ "${ARGS}" == *enable-cbom-generation-task* ]]; then
  STATUS="${OC_ENABLE_STATUS:-0}"
  VALUE="${OC_ENABLE_VALUE:-}"
elif [[ "${ARGS}" == *additional-cbom-generation-rules-image* ]]; then
  STATUS="${OC_RULES_STATUS:-0}"
  VALUE="${OC_RULES_VALUE:-}"
else
  echo "stub oc: unexpected invocation: ${ARGS}" >&2
  exit 97
fi

# A ConfigMap (or namespace) that does not exist. Real `oc` applies
# --ignore-not-found at the resource-builder level, so it exits 0 with no
# output regardless of -o jsonpath; without the flag it is a hard error.
if [[ "${OC_CONFIGMAP_MISSING:-false}" == "true" ]]; then
  if [[ "${ARGS}" == *--ignore-not-found* ]]; then
    exit 0
  fi
  echo 'Error from server (NotFound): configmaps "cluster-config" not found' >&2
  exit 1
fi

if [[ "${STATUS}" -ne 0 ]]; then
  echo 'Error from server (Forbidden): configmaps "cluster-config" is forbidden' >&2
  exit "${STATUS}"
fi

printf '%s' "${VALUE}"
STUB
  chmod +x "${TMPROOT}/bin/oc"
}

CASE_DIR=""
CASE_STATUS=0
CASE_MARKER=""

# run_case <label> <task-yaml> <task-name> [VAR=value ...]
run_case() {
  local label="$1" task_yaml="$2" task_name="$3"
  shift 3

  CASE_DIR="${TMPROOT}/${task_name}--${label}"
  mkdir -p "${CASE_DIR}/ws" "${CASE_DIR}/workdir"

  extract_step "${task_yaml}" pull-rules "${CASE_DIR}/pull-rules.sh" \
    "${CASE_DIR}/ws" "${CASE_DIR}/workdir" "${task_name}"

  set +e
  env -u OC_ENABLE_STATUS -u OC_ENABLE_VALUE \
      -u OC_RULES_STATUS -u OC_RULES_VALUE -u OC_CONFIGMAP_MISSING \
      "$@" PATH="${TMPROOT}/bin:${PATH}" \
      bash "${CASE_DIR}/pull-rules.sh" > "${CASE_DIR}/out.log" 2>&1
  CASE_STATUS=$?
  set -e

  CASE_MARKER="$(find "${CASE_DIR}" -type f -name warnings | head -n 1)"
}

pass() {
  PASSES=$((PASSES + 1))
  echo "  ok   - $1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  echo "  FAIL - $1"
  echo "         step output:"
  sed 's/^/         | /' "${CASE_DIR}/out.log"
}

# check <description> <expected-status> <marker|no-marker> <expected-substring>
check() {
  local description="$1" want_status="$2" want_marker="$3" want_text="$4"

  if [[ "${CASE_STATUS}" -ne "${want_status}" ]]; then
    fail "${description} (exit ${CASE_STATUS}, want ${want_status})"
    return
  fi

  if [[ "${want_marker}" == "marker" ]]; then
    if [[ -z "${CASE_MARKER}" ]]; then
      fail "${description} (no warnings marker written)"
      return
    fi
    if [[ "$(cat "${CASE_MARKER}")" != "1" ]]; then
      fail "${description} (warnings marker is not 1)"
      return
    fi
  elif [[ -n "${CASE_MARKER}" ]]; then
    fail "${description} (unexpected warnings marker at ${CASE_MARKER})"
    return
  fi

  if ! grep -qF "${want_text}" "${CASE_DIR}/out.log"; then
    fail "${description} (output missing: ${want_text})"
    return
  fi

  pass "${description}"
}

# --- behaviour tests -------------------------------------------------------

test_flavour() {
  local task_yaml="$1" task_name="$2"
  echo "${task_name}"

  # A cluster with no cluster-config ConfigMap is opting out exactly as an
  # unset key does, so it must stay on the silent-skip path.
  run_case configmap-missing "${task_yaml}" "${task_name}" \
    FORCE_CBOM=false FORCE_RULES_IMAGE= OC_CONFIGMAP_MISSING=true
  check "missing ConfigMap skips quietly" 0 no-marker "is not enabled on this cluster"

  # A genuine lookup failure must be visible downstream.
  run_case enable-lookup-fails "${task_yaml}" "${task_name}" \
    FORCE_CBOM=false FORCE_RULES_IMAGE= OC_ENABLE_STATUS=1
  check "failed enable-cbom lookup warns" 0 marker "WARNING: Unable to read 'enable-cbom-generation-task'"

  run_case enable-key-empty "${task_yaml}" "${task_name}" \
    FORCE_CBOM=false FORCE_RULES_IMAGE= OC_ENABLE_VALUE=
  check "empty enable-cbom key skips quietly" 0 no-marker "is not enabled on this cluster"

  run_case enable-key-false "${task_yaml}" "${task_name}" \
    FORCE_CBOM=false FORCE_RULES_IMAGE= OC_ENABLE_VALUE=false
  check "enable-cbom=false skips quietly" 0 no-marker "is not enabled on this cluster"

  run_case rules-lookup-fails "${task_yaml}" "${task_name}" \
    FORCE_CBOM=false FORCE_RULES_IMAGE= OC_ENABLE_VALUE=true OC_RULES_STATUS=1
  check "failed rules-image lookup warns" 0 marker "WARNING: Unable to read 'additional-cbom-generation-rules-image'"

  run_case rules-key-empty "${task_yaml}" "${task_name}" \
    FORCE_CBOM=false FORCE_RULES_IMAGE= OC_ENABLE_VALUE=true OC_RULES_VALUE=
  check "unset rules image skips quietly" 0 no-marker "No additional rules image configured"

  # FORCE_CBOM bypasses the enable lookup entirely, so a broken enable lookup
  # must not matter.
  run_case force-cbom "${task_yaml}" "${task_name}" \
    FORCE_CBOM=true FORCE_RULES_IMAGE= OC_ENABLE_STATUS=1 OC_RULES_VALUE=
  check "FORCE_CBOM skips the enable lookup" 0 no-marker "No additional rules image configured"
}

# --- flavour parity --------------------------------------------------------

test_parity() {
  echo "flavour parity"

  extract_step "${NON_TA_YAML}" pull-rules "${TMPROOT}/non-ta-raw.sh" \
    DIR DIR TASK
  extract_step "${TA_YAML}" pull-rules "${TMPROOT}/ta-raw.sh" \
    DIR DIR TASK

  # Ignore blank lines and the intentionally different WARNINGS_DIR value.
  for variant in non-ta ta; do
    grep -v '^[[:space:]]*$' "${TMPROOT}/${variant}-raw.sh" \
      | grep -v '^[[:space:]]*WARNINGS_DIR=' > "${TMPROOT}/${variant}-norm.sh"
  done

  CASE_DIR="${TMPROOT}"
  : > "${CASE_DIR}/out.log"
  if diff -u "${TMPROOT}/non-ta-norm.sh" "${TMPROOT}/ta-norm.sh" > "${CASE_DIR}/out.log" 2>&1; then
    pass "both pull-rules scripts differ only in WARNINGS_DIR"
  else
    fail "both pull-rules scripts differ only in WARNINGS_DIR"
  fi
}

# --- main ------------------------------------------------------------------

make_stub_oc

test_flavour "${NON_TA_YAML}" "${NON_TA_NAME}"
test_flavour "${TA_YAML}" "${TA_NAME}"
test_parity

echo
echo "${PASSES} passed, ${FAILURES} failed"
test "${FAILURES}" -eq 0

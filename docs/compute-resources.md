# Compute resources

Every step of both task flavors declares a `computeResources` block. Those
numbers are not local to this repository: a `requests` value is a hard
scheduling reservation imposed on every pipeline that consumes the published
bundle, and a missing `limits` value hands the step whatever the consuming
namespace happens to allow.

This file is the in-repo record of what the numbers are, where they came from,
and which rules they have to satisfy. It exists because that record was
missing: between releases 0.2.1 and 0.3.1 the scanner step was retuned twice
and no reviewer working from the repository alone could tell a deliberate value
from an accidental one.

## Convention: sizing evidence must be reachable from the repository

A pull request that changes any `computeResources` value must:

1. update the table below, and
2. carry a short measurement summary — what was measured, against which
   workload, when — in its CHANGELOG entry or in the pull request body.

A bare ticket reference is not enough. The review sandbox used on this
repository can reach `api.github.com` and `github.com` and nothing else (see
`.fullsend/profiles/fullsend-github-ro.yaml`), so sizing evidence that lives
only in an external tracker is unreadable to every automated reviewer by
construction, and the same question gets re-litigated on every tuning PR.

A summary that only restates the value ("set to 4 cores because the scanner
needs 4 cores") is not a measurement summary.

## Current values

`∅` means the value is intentionally not declared; see the CPU-limit policy
below.

| Step | Flavors | requests | limits | Last changed | Basis for the number |
|---|---|---|---|---|---|
| `use-trusted-artifact` | oci-ta | cpu 60m, memory 64Mi | cpu ∅, memory 512Mi | 0.3.1 | **Not recorded.** The step was given a 4Gi request/limit in 0.2.1, cut to 64Mi in 0.3.1, and the limit was then raised to 512Mi during review of that change. No measurement is recorded for any of the three values. |
| `pull-rules` | both | cpu 100m, memory 256Mi | cpu ∅, memory 256Mi | 0.2.1 | **Not recorded.** Introduced with the initial `computeResources` rollout. The step pulls the proprietary rules image and is dominated by network transfer, not compute. |
| `rh-crypto-scanner` | both | cpu "4", memory 2Gi | cpu "8", memory 8Gi | 0.3.2 | **Partially recorded.** The cpu request (1 → 4) and the memory limit (4Gi → 8Gi) were raised in 0.3.1 against measurements that were never written down here. The cpu limit of "8" is the ceiling that shipped in 0.2.1 through 0.3.0; it was dropped in 0.3.1 and restored in 0.3.2 (see "Known gaps"). |
| `update-cbom-metadata` | both | cpu 100m, memory 512Mi | cpu ∅, memory 512Mi | 0.2.2 | **Not recorded.** Introduced with the Mobster step. It rewrites CBOM metadata in place and is short-lived. |
| `upload` | both | cpu 100m, memory 256Mi | cpu ∅, memory 256Mi | 0.2.1 | **Not recorded.** Introduced with the initial `computeResources` rollout. The step attaches a single blob with `oras` and is dominated by network transfer. |

The four steps shared by both flavors must declare identical values; the hook
described below enforces that.

## Known gaps

These are the questions this file cannot answer yet. They are not blockers for
consumers, but the record is incomplete until a maintainer fills them in.

* **What workload were the 0.3.1 scanner numbers measured against?** `cpu: "4"`
  and `memory: 8Gi` were tuned against measurements recorded in an external
  tracker. Which repository, how large, and on which cluster is unknown here.
* **Is a 4-core reservation right for every consumer?** It is a reservation,
  not a ceiling: every pipeline that includes this task pays it on every build,
  including small components.
* **Was dropping `limits.cpu` in 0.3.1 deliberate?** Nothing in the repository
  said so, and the reviewer could not tell. Release 0.3.2 restores the "8"
  ceiling that 0.2.1 through 0.3.0 shipped, so the step is no longer CPU
  unbounded and is no better or worse off than it was at 0.3.0. If the removal
  *was* deliberate — for example because the consuming namespaces supply a
  LimitRange default, or because throttling was measured to hurt scan latency —
  then delete `limits.cpu` again and record that reason with the opt-out
  comment described below. Either outcome settles the question; the current
  state is chosen because it is the one that does not depend on cluster
  configuration that is not checked in here.

## CPU-limit policy

* A step that reserves a full core or more declares `limits.cpu`. A large CPU
  request with no ceiling is rejected outright if the consuming namespace has a
  LimitRange default below the request, and is otherwise unbounded on shared
  build infrastructure.
* A sub-core step may omit `limits.cpu`, because a ceiling that close to the
  request buys nothing and only adds CFS throttling to short, mostly
  network-bound work. The omission still has to be recorded, next to the
  block it applies to:

  ```yaml
        # resource-check: no-cpu-limit - sub-core request for a short upload step
        computeResources:
          limits:
            memory: 256Mi
          requests:
            cpu: 100m
            memory: 256Mi
  ```

  The marker is `# resource-check: no-cpu-limit`, followed by the reason on the
  same line. It must sit within the two lines above `computeResources:` or
  inside the block itself, and it must be removed when a CPU limit is added.

## The pre-commit hook

[`hack/check-compute-resources.py`](../hack/check-compute-resources.py) runs
from `.pre-commit-config.yaml` whenever a task file changes, and can be run by
hand:

```bash
./hack/check-compute-resources.py
```

It fails when, for any step of either task file:

1. `computeResources` is missing, or either `requests` or `limits` is missing;
2. `requests.memory` is declared without `limits.memory`, or exceeds it;
3. `requests.cpu` is declared without `limits.cpu` and without the opt-out
   comment, or `limits.cpu` is lower than `requests.cpu`;
4. a step shared by both flavors is sized differently in the two files.

An opt-out comment with no reason, a stale opt-out comment left next to a
declared `limits.cpu`, and a quantity that is not a valid Kubernetes quantity
are all failures too.

The hook is only as good as its installation — it is not enforced in CI. Run
`pre-commit install` after cloning.

## Changing a value

1. Measure, and write down what you measured against.
2. Change both task files if the step is shared.
3. Update the table above, including the "Last changed" and "Basis" columns.
4. Bump `app.kubernetes.io/version` in both task files, add a CHANGELOG entry
   per flavor carrying the measurement summary, and update the bundle tag in
   the top-level README.
5. Run `./hack/check-compute-resources.py`.

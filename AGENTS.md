# AGENTS.md

Conventions for `rh-pvsec/crypto-scanner-tasks`, written down so that
reviewers — human or automated — do not have to re-derive them from `git log`
on every pull request.

Everything stated as a convention below is either observable in the current
tree or was answered by a maintainer on a merged pull request. Where a claim
rests on a maintainer's answer rather than on the tree, the entry names the
pull request it came from; an uncited claim is one you can read off the tree
and check. Items that the maintainers have not decided yet are collected under
[Open questions](#open-questions) rather than being asserted as policy. That
section records what is still open and where it is tracked, so a finding on one
of those topics can cite the current state alongside its own conclusion.

## Repository layout

The whole repository is a handful of files:

| Path | What it is |
|---|---|
| `task/sast-crypto-scan/` | Task flavor that takes source from a Tekton **workspace** |
| `task/sast-crypto-scan-oci-ta/` | Task flavor that takes source from a **Trusted Artifact** |
| `.tekton/` | Konflux build pipelines that build and push *this repo's own* task bundles |
| `.github/workflows/fullsend.yaml` | The only GitHub Actions workflow |
| `README.md` | Consumer-facing usage, cluster support matrix, contributing notes |
| `AGENTS.md` | This file |
| `renovate.json` | MintMaker/Renovate config; automerges `.tekton/**` only (see [Image pinning](#image-pinning)) |
| `.pre-commit-config.yaml` | The single local hook, `gitleaks` (see [Local checks](#local-checks)) |
| `.pr_agent.toml` | PR-agent config; currently sets only `ignore_pr_authors` |
| `.fullsend/` | Fullsend configuration; `config.yaml` enables the triage, coder, review and fix roles |

Each `task/<name>/` directory holds exactly three files: `<name>.yaml`,
`README.md` (a generated-looking parameter/result table), and `CHANGELOG.md`.

There is no test suite and no build step. The only automated local check is
`pre-commit` (see [Local checks](#local-checks)).

## Task-authoring conventions

### Both flavors change together

`sast-crypto-scan` and `sast-crypto-scan-oci-ta` are maintained as a matched
pair. A change to one is almost always a bug if it is not mirrored in the
other, and both flavors are released under the same version number.

They are **not** identical, and the differences are deliberate. As of `0.2.2`
the full list of semantic differences is:

- **Source acquisition.** The `-oci-ta` flavor declares a `SOURCE_ARTIFACT`
  param, a `workdir` `emptyDir` volume, a `stepTemplate` mounting it at
  `/var/workdir`, and a leading `use-trusted-artifact` step. The plain flavor
  declares a `workspaces:` entry named `workspace` instead and has no
  equivalent step.
- **Paths.** `-oci-ta` uses two literal roots under `/var/workdir`:
  `/var/workdir/source` for the source tree, and
  `/var/workdir/$(context.task.name)` for the soft-failure `warnings` marker.
  The plain flavor uses `$(workspaces.workspace.path)/...` for both and
  additionally passes `WORKSPACE_PATH` into the `rh-crypto-scanner` step as an
  env var, which that step's script uses to build `SOURCE_CODE_DIR`.
- **`workingDir`.** `/var/workdir/source` versus
  `$(workspaces.workspace.path)/hacbs/$(context.task.name)`.
- **Identity fields.** `metadata.name` is the flavor's own name, and
  `spec.description` embeds that same name in its opening sentence. These
  differ by definition and are not drift.

Nothing else should diverge semantically. In particular the step list after
`use-trusted-artifact` (`pull-rules` → `rh-crypto-scanner` →
`update-cbom-metadata` → `upload`), the params, the results, the
`computeResources`, and the script bodies are expected to match.

Check this against the tree with `diff
task/sast-crypto-scan-oci-ta/sast-crypto-scan-oci-ta.yaml
task/sast-crypto-scan/sast-crypto-scan.yaml`.

That diff also reports two formatting-only divergences that are not in the
list above: the `trusted-ca` volume's configMap keys are ordered differently
between the two files (`name` before `items` in the plain flavor, the reverse
in `-oci-ta`), and a few blank or trailing-whitespace lines inside the step
scripts differ. Both are inert, and normalizing them would make the list
above literally true.

### Image pinning

Step images are pinned as `name:tag@sha256:<digest>`. Current examples:
`build-trusted-artifacts`, `task-runner`, `mobster`, and `oras`.

These digests are bumped by hand, in the PR that needs the new image.
Renovate/MintMaker is configured to automerge only `.tekton/**` (see
`renovate.json`), so do not assume a bot will refresh a `task/**` digest for
you.

Two images are deliberately left on a mutable tag. No tracking issue covers
them today, so — unlike the root grant below, which #50 bounds — this is a
record of current state rather than a time-bounded exception, and the two
entries do not rest on equally firm ground:

- `quay.io/exd-guild-security/crypto-finder-image:latest` (the
  `rh-crypto-scanner` step) is unpinned. The reason given here — that it lets
  the scanner pick up the latest released build — is **inferred, not
  confirmed**: there is no comment at the image reference in either flavor and
  no maintainer statement to cite. This one is worth a maintainer confirming
  or pinning, since it is the image that executes the scan over consumer
  source.
- `crypto-rules-image:latest`, resolved inside the `pull-rules` script, is
  intentionally unpinned — the comment directly above the `IMAGE=` assignment
  in that script says so ("This unpinned image contain the latest rolling
  version of the rules"). It is the rolling proprietary rules image.

Scratch tags from `quay.io/redhat-user-workloads/...` must never appear in
`task/**`. They are legitimate in `.tekton/**`, which is where Konflux pushes
this repository's own on-PR and on-push bundle builds, so a
`redhat-user-workloads` reference under `.tekton/` is expected and correct.

A registry path that merely *looks* like a scratch build is not automatically
one. On [#42](https://github.com/rh-pvsec/crypto-scanner-tasks/pull/42) the
`mobster:2.4.0-1793708943@sha256:...` tag was questioned and the author
confirmed it is the official released `quay.io/konflux-ci/mobster` image; the
unreleased image that had been committed by mistake was in a different Quay
repository and was replaced before merge. Check the registry namespace, not the
shape of the tag.

### Gating on `SKIP_SBOM_GENERATION`

Gating is split by step, and the split is intentional:

- `pull-rules` uses a Tekton `when` clause
  (`operator: notin`, `values: ["true"]`).
- `rh-crypto-scanner`, `update-cbom-metadata`, and `upload` gate **inside the
  script** with `if [ "${SKIP_SBOM_GENERATION}" = "true" ]`, taking
  `SKIP_SBOM_GENERATION` in as an env var.

The in-script form is what lets `rh-crypto-scanner` still emit a `TEST_OUTPUT`
result of `SKIPPED` rather than being skipped outright and producing no result
at all. New steps that must still report something should follow the in-script
form; `0.1.2` moved this flow to script level deliberately ("Manage
SKIP_SBOM_GENERATION flow at script level" in both CHANGELOGs).

`update-cbom-metadata` and `upload` additionally no-op when `image-url` or
`image-digest` is empty, because both params default to `""`.

### Steps run as root in this pipeline

What UID a step runs as is decided by its image's own `USER` directive and by
the cluster's security context constraints — not by the presence or absence of
a `securityContext` block in the task YAML. The steps that precede
`update-cbom-metadata` carry no `securityContext`, and their images happen to
default to root, so the scanner writes root-owned files into the working
directory. A later step that **mutates** those files therefore has to run as
UID 0 too. The `mobster` image that `update-cbom-metadata` uses evidently does
*not* default to root — that is the inference from the permission-denied
failure recorded below, not a checked `USER` directive — so that step is the
one that has to say so explicitly.

That is why `update-cbom-metadata` carries:

```yaml
      securityContext:
        runAsUser: 0
```

On [#42](https://github.com/rh-pvsec/crypto-scanner-tasks/pull/42) the author
confirmed this directly: the first version of the step ran without it and
failed with a permission-denied error when rewriting `cbom.json`.

This is a recorded fact about the current pipeline, not an endorsement.
Issue [#50](https://github.com/rh-pvsec/crypto-scanner-tasks/issues/50) tracks
reviewing every step and image to see whether user execution can be
restricted. **If #50 is resolved by dropping the root grant, update this
section.**

The UID-0 requirement on `update-cbom-metadata` originates in the
permission-denied failure described above; whether granting it is the right
fix is still open in #50. Re-evaluate it if the step's script or image
changes, or if #50 lands.

The account is also incomplete, and the gap is worth seeing from this file
alone: neither flavor declares `allowPrivilegeEscalation`, `capabilities`, or
`runAsNonRoot` anywhere, and #50's suggested fix asks for
`allowPrivilegeEscalation: false` and `capabilities: drop: ["ALL"]` to
accompany the grant. Whatever #50 decides about the UID itself, that
hardening is not present today.

That rationale is specific to this one step. A root grant on any *new* step is
worth flagging, as are `privileged`, host namespaces, `hostPath`, or *added*
capabilities anywhere — none of which exist in this repository today. "No
added capabilities" is a different statement from the absent capability drop
described above; neither implies the other.

### `mobster generate oci-cbom` does no registry I/O

`update-cbom-metadata` does not call `select-oci-auth` and does not need to.
`mobster generate oci-cbom` derives PURLs from the `image-url` and
`image-digest` params and from the `cbom.json` already on disk; it does not
pull or push anything. The author confirmed this on
[#42](https://github.com/rh-pvsec/crypto-scanner-tasks/pull/42).

Contrast with the `upload` step, which *does* talk to the registry via
`oras attach` and therefore *does* call `select-oci-auth`. The asymmetry is
correct.

The `trusted-ca` mount on `update-cbom-metadata` is a separate question — see
[Open questions](#open-questions).

### Other step conventions

- Every step declares `computeResources` with both `limits` and `requests`
  (added in `0.2.1`). New steps must too.
- Step scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Both flavors write results through `$(results.TEST_OUTPUT.path)` from the
  `rh-crypto-scanner` step only.
- The soft-failure path for proprietary rules writes a `warnings` file that
  `rh-crypto-scanner` reads to turn `RESULT` into `WARNING`. Preserve that
  mechanism when touching `pull-rules`.

## Release conventions

### Three version sites move in lockstep

A release touches all of these. Sites 1 and 2 exist for **both** flavors;
site 3 exists once:

1. `app.kubernetes.io/version` in `task/<name>/<name>.yaml`
2. The topmost `## <version>` heading in `task/<name>/CHANGELOG.md`
3. The bundle tag in the usage snippet in the root `README.md`. There is only
   one such snippet and it is pinned to the `-oci-ta` bundle. The plain
   flavor's registry path is mentioned earlier in that README without a
   version, so there is no second README tag to bump.

Site 3 is the one that gets missed, because `README.md` is usually not part of
the diff and an inline review comment cannot be attached to it. Commit
`06dfaba` ("Update README.md") exists only to repair that drift. Issue
[#51](https://github.com/rh-pvsec/crypto-scanner-tasks/issues/51) tracks both
the live drift and a proposed CI check for it; compare the three sites
yourself rather than trusting a recorded snapshot, and do not fix drift as a
drive-by in an unrelated PR.

### Check `main` before choosing a version

Decide the new version against what is **already on `main`**, not against the
version at your branch point. This is a real failure mode here: on
[#42](https://github.com/rh-pvsec/crypto-scanner-tasks/pull/42) `0.2.1` landed
on `main` while the PR was in review, and the branch had to be rebased and
re-bumped to `0.2.2`.

Reviewers cannot see this from the diff alone. State the version you are
bumping *from* and *to* in the PR, and re-check before merge.

### Patch versus minor

The one decision the maintainers have made explicitly: on
[#42](https://github.com/rh-pvsec/crypto-scanner-tasks/pull/42), adding the
`update-cbom-metadata` step — a new step, with new content in the emitted CBOM
— was released as the **patch** `0.2.2`, not as `0.3.0`. The stated reason was
that nothing changed from the user's perspective: no new required param, no
change to how the task is invoked, no change to the task's contract with its
consumers.

Commit `f4a072f` ("Switch to increase a minor bump in the version") is
sometimes cited as precedent for a minor bump on a feature-shaped change. Read
in context it says the opposite. `f4a072f` is a commit *inside*
[#41](https://github.com/rh-pvsec/crypto-scanner-tasks/pull/41), the PR that
removed the obsolete `CACHI2_ARTIFACT` parameter; it re-targeted that release
from `0.1.4` to `0.2.0`. Removing a parameter from user pipelines **is** a
consumer-visible change, so the minor bump there and the patch bump on #42 are
consistent, not contradictory.

The working rule both data points support — a candidate description of
observed behavior, not a ratified convention:

- Bump **minor** when a consumer has to change something: a param added as
  required, a param removed, a change to how the task is invoked or what it
  guarantees.
- Bump **patch** otherwise, including for new steps that are invisible from
  the pipeline author's side.

This rule is inferred from two releases rather than ratified by the
maintainers — see [Open questions](#open-questions). Argue from consumer
impact, not from the shape of the diff, and accept a maintainer's call.

### CHANGELOG format

Both CHANGELOGs follow [keepachangelog](https://keepachangelog.com/en/1.1.0/#how),
as the comment at the top of each file states. Under that format:

- `### Added` — new steps, new params, new capabilities.
- `### Changed` — changes to behavior that already existed.
- `### Removed` — deleted params or steps (see `0.2.0` in the `-oci-ta`
  CHANGELOG).

Existing entries are not perfectly consistent with this: the `0.2.2` entry
files a brand-new step under `### Changed`, where `### Added` fits better.
Prefer the keepachangelog semantics for new entries; rewriting history in old
entries is not worth a PR on its own.

Both CHANGELOGs get the same heading and, in practice, near-identical bullets.

## Commits and branches

Observed in recent history, in rough order of recency:

- Conventional Commits with a **Jira issue key as the scope**:
  `feat(ISV-7778): ...`, `chore(ISV-7778): ...`.
- Branch names carry the Jira key too (`BorekZnovustvoritel/ISV-7778`), or a
  short topic (`remove_cachi2`, `gitleaks`, `set_computeresources`).
- Older commits are plain imperative subjects with no type prefix
  (`Add precommit check for gitleaks`).

There is no commit linter configured, so none of this is enforced.

## Local checks

```bash
pip install pre-commit
pre-commit install
```

`.pre-commit-config.yaml` currently has exactly one hook: `gitleaks`. There is
no YAML linter, no schema validation of the Tekton files, and no test suite, so
`pre-commit` passing means only that no secret was detected.

## Open questions

These are **not decided**. They are listed here so that they get settled once,
in a PR that is about settling them, instead of being re-litigated on every
review. Each entry records what is open and where it is tracked; raising a
finding on one of these topics remains legitimate, and linking the entry tells
the reader how far the question has got.

1. **Is the `trusted-ca` mount on `update-cbom-metadata` still required?**
   The step performs no registry or network I/O, so on the face of it the CA
   bundle is unnecessary. The author kept it because he was unsure whether the
   mount has other implications on the cluster. Needs a maintainer to confirm
   it can be dropped.

2. **May CBOM metadata enrichment fail the TaskRun?**
   As written, `update-cbom-metadata` runs under `set -euo pipefail` and sits
   *before* `upload`, so any `mobster generate` failure aborts the task and no
   CBOM is uploaded at all. Whether enrichment should be fatal, or should warn
   and let the un-enriched CBOM upload, was raised in review on #42 and merged
   undecided.

3. **Should the consumer-impact rule for patch-versus-minor be ratified?**
   The rule stated above is consistent with both releases where the question
   came up (`0.2.0` and `0.2.2`), but it was inferred here rather than agreed
   by the maintainers. Confirming it — or replacing it — would settle the
   most frequently re-argued review topic in this repository.

4. **What is the policy on PR bodies, linked issues, and Jira references, and
   which paths genuinely require human sign-off?**
   There is no `CODEOWNERS`, no pull request template, and no stated policy in
   this repository, so automated findings of the form "the PR body is empty and
   no issue is linked, therefore a human must approve" currently have no
   in-repo rule to appeal to. Writing the real policy down here — whatever it
   turns out to be — is the useful outcome. This entry records only that no
   in-repo authorization rule exists yet; nothing in this file authorizes a
   merge, and no branch-name or commit-scope convention substitutes for human
   approval unless a maintainer states otherwise here.

## Related

- [#50](https://github.com/rh-pvsec/crypto-scanner-tasks/issues/50) — revisit
  root execution across steps and images (affects the `runAsUser: 0` rationale
  above)
- [#51](https://github.com/rh-pvsec/crypto-scanner-tasks/issues/51) — the
  live README/task version drift, and a CI check for the three-site version
  lockstep

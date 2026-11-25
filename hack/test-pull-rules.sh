#!/usr/bin/env bash
#
# Regression tests for the `pull-rules` step script shared by both crypto
# scan task flavours.
#
# The step script lives inside the task YAML, so this harness extracts it,
# runs it under bash against a stubbed `oc`/`curl`, and asserts:
#
#   * the registry dispatch matrix (issue #83) -- which hosts are accepted,
#     which are rejected, and what each accepted host does to ROBOT_ACCOUNT
#     and SSL_CERT_FILE;
#   * that the rules image pullspec reaches `oc image extract` after a `--`
#     terminator;
#   * that the dispatch block is byte-identical across the two flavours.
#
# No cluster is required. Usage:
#
#   ./hack/test-pull-rules.sh
#
set -euo pipefail

EXECDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPODIR="$(cd "${EXECDIR}/.." && pwd)"
WORKDIR="$(mktemp -d "/tmp/$(basename "$0").XXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

PLAIN_YAML="${REPODIR}/task/sast-crypto-scan/sast-crypto-scan.yaml"
OCI_TA_YAML="${REPODIR}/task/sast-crypto-scan-oci-ta/sast-crypto-scan-oci-ta.yaml"

FAILURES=0
CHECKS=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

cat > "${WORKDIR}/extract.py" <<'EXTRACT_PY'
"""Print a Tekton step script, with Tekton substitutions resolved.

The absolute roots the step writes to (/workspace for the workspace flavour,
/var/workdir for the Trusted Artifacts flavour) are repointed inside the
throwaway run directory so the script can run unprivileged.
"""
import sys

import yaml

yaml_path, step_name, run_dir, task_name = sys.argv[1:5]

with open(yaml_path, encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

for step in doc["spec"]["steps"]:
    if step["name"] == step_name:
        script = step["script"]
        break
else:
    sys.exit("step not found: {}".format(step_name))

# Order matters: rewrite the literal roots before expanding the Tekton
# workspace substitution, which expands to one of those rewritten roots.
script = script.replace("/var/workdir", run_dir + "/var/workdir")
script = script.replace("/workspace", run_dir + "/workspace")
script = script.replace("$(workspaces.workspace.path)", run_dir + "/workspace")
script = script.replace("$(context.task.name)", task_name)
sys.stdout.write(script)
EXTRACT_PY

extract_step_script() {
  # extract_step_script <yaml> <step> <run-dir> <task-name>
  python3 "${WORKDIR}/extract.py" "$1" "$2" "$3" "$4"
}

# Stubs prepended to the step script. Shell functions shadow the real
# binaries, so the step script itself is executed verbatim.
cat > "${WORKDIR}/preamble.sh" <<'PREAMBLE'
oc() {
  case "${1:-} ${2:-}" in
    "get configmap")
      case "$*" in
        *enable-cbom-generation-task*) printf '%s' "${STUB_ENABLE_CBOM}" ;;
        *additional-cbom-generation-rules-image*) printf '%s' "${STUB_RULES_IMAGE}" ;;
        *) return 1 ;;
      esac
      ;;
    "registry login")
      printf 'registry-login %s\n' "$*" >> "${STUB_ARGV_FILE}"
      ;;
    "image extract")
      { printf 'image-extract'
        for __a in "$@"; do printf ' <%s>' "${__a}"; done
        printf '\n'
      } >> "${STUB_ARGV_FILE}"
      ;;
    *)
      printf 'unexpected oc invocation: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

curl() {
  if [ "${STUB_TOKEN_EXCHANGE:-ok}" = "fail" ]; then
    return 22
  fi
  printf '{"token": "stub-federation-token"}'
}

retry() { "$@"; }

# The bound service-account token is projected into the pod at runtime.
cat() {
  if [ "${1:-}" = "/var/run/secrets/tokens/quay-token" ]; then
    printf '%s' "${STUB_BOUND_TOKEN-stub-bound-token}"
    return 0
  fi
  command cat "$@"
}

__record_state() {
  local __rc=$?
  { printf 'exit=%s\n' "${__rc}"
    printf 'ROBOT_ACCOUNT=%s\n' "${ROBOT_ACCOUNT-<unset>}"
    printf 'SSL_CERT_FILE=%s\n' "${SSL_CERT_FILE-<unset>}"
  } > "${STUB_STATE_FILE}"
}
trap __record_state EXIT
PREAMBLE

# run_step <yaml> <task-name> <force-rules-image> <configmap-rules-image> <enable-cbom>
#
# Populates the globals RUN_EXIT, RUN_ROBOT_ACCOUNT, RUN_SSL_CERT_FILE,
# RUN_STDERR and RUN_ARGV.
run_step() {
  local yaml="$1" task_name="$2" force_image="$3" cm_image="$4" enable_cbom="$5"
  local run
  run="$(mktemp -d "${WORKDIR}/run.XXXX")"
  mkdir -p "${run}/workspace" "${run}/var/workdir"

  extract_step_script "${yaml}" pull-rules "${run}" "${task_name}" \
    > "${run}/body.sh"
  cat "${WORKDIR}/preamble.sh" "${run}/body.sh" > "${run}/step.sh"

  : > "${run}/argv"
  : > "${run}/state"

  set +e
  env -i \
    PATH="${PATH}" \
    HOME="${run}" \
    FORCE_CBOM=false \
    FORCE_RULES_IMAGE="${force_image}" \
    STUB_ENABLE_CBOM="${enable_cbom}" \
    STUB_RULES_IMAGE="${cm_image}" \
    STUB_ARGV_FILE="${run}/argv" \
    STUB_STATE_FILE="${run}/state" \
    STUB_TOKEN_EXCHANGE="${STUB_TOKEN_EXCHANGE:-ok}" \
    bash "${run}/step.sh" > "${run}/stdout" 2> "${run}/stderr"
  set -e

  RUN_EXIT="$(state_get "${run}/state" exit)"
  RUN_ROBOT_ACCOUNT="$(state_get "${run}/state" ROBOT_ACCOUNT)"
  RUN_SSL_CERT_FILE="$(state_get "${run}/state" SSL_CERT_FILE)"
  RUN_STDERR="$(cat "${run}/stderr")"
  RUN_ARGV="$(cat "${run}/argv")"
}

state_get() {
  grep "^$2=" "$1" | head -1 | cut -d= -f2-
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  CHECKS=$((CHECKS + 1))
  if [ "${expected}" = "${actual}" ]; then
    printf '      ok   %s\n' "${label}"
  else
    printf '      FAIL %s: expected [%s], got [%s]\n' "${label}" "${expected}" "${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  CHECKS=$((CHECKS + 1))
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '      ok   %s\n' "${label}"
  else
    printf '      FAIL %s: [%s] not found in [%s]\n' "${label}" "${needle}" "${haystack}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --------------------------------------------------------------------------
# Dispatch matrix, asserted identically for both flavours
# --------------------------------------------------------------------------

SUPPORTED_REGISTRIES="Supported registries: quay.io, quay.io:443, image-registry.openshift-image-registry.svc:5000, image-registry.openshift-image-registry.svc.cluster.local:5000"
QUAY_ROBOT_ACCOUNT="exd-guild-security+konflux_crypto_rules_pull"
SERVICE_CA="/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"

check_accepted_quay() {
  local yaml="$1" task_name="$2" image="$3"
  printf '    accepted (quay): %s\n' "${image}"
  run_step "${yaml}" "${task_name}" "${image}" "" true
  assert_eq "exit status" 0 "${RUN_EXIT}"
  assert_eq "ROBOT_ACCOUNT" "${QUAY_ROBOT_ACCOUNT}" "${RUN_ROBOT_ACCOUNT}"
  assert_eq "SSL_CERT_FILE untouched" "<unset>" "${RUN_SSL_CERT_FILE}"
  assert_contains "pullspec after --" "<--> <${image}>" "${RUN_ARGV}"
}

check_accepted_internal() {
  local yaml="$1" task_name="$2" image="$3"
  printf '    accepted (in-cluster): %s\n' "${image}"
  run_step "${yaml}" "${task_name}" "${image}" "" true
  assert_eq "exit status" 0 "${RUN_EXIT}"
  assert_eq "ROBOT_ACCOUNT empty" "" "${RUN_ROBOT_ACCOUNT}"
  assert_eq "SSL_CERT_FILE" "${SERVICE_CA}" "${RUN_SSL_CERT_FILE}"
  assert_contains "pullspec after --" "<--> <${image}>" "${RUN_ARGV}"
}

check_rejected() {
  local yaml="$1" task_name="$2" image="$3" expected_message="$4"
  printf '    rejected: %s\n' "${image}"
  run_step "${yaml}" "${task_name}" "${image}" "" true
  assert_eq "exit status" 1 "${RUN_EXIT}"
  assert_eq "SSL_CERT_FILE untouched" "<unset>" "${RUN_SSL_CERT_FILE}"
  assert_contains "error message" "${expected_message}" "${RUN_STDERR}"
  assert_eq "no image pulled" "" "${RUN_ARGV}"
}

check_flavour() {
  local yaml="$1" task_name="$2"
  printf '  %s\n' "${task_name}"

  check_accepted_quay "${yaml}" "${task_name}" "quay.io/exd-guild-security/crypto-rules:latest"
  check_accepted_quay "${yaml}" "${task_name}" "quay.io:443/exd-guild-security/crypto-rules:latest"

  check_accepted_internal "${yaml}" "${task_name}" \
    "image-registry.openshift-image-registry.svc:5000/konflux/crypto-rules:latest"
  # The service CA serving cert also covers the .cluster.local FQDN.
  check_accepted_internal "${yaml}" "${task_name}" \
    "image-registry.openshift-image-registry.svc.cluster.local:5000/konflux/crypto-rules:latest"

  check_rejected "${yaml}" "${task_name}" "harbor.example.com/crypto-rules:latest" \
    "Unsupported rules registry 'harbor.example.com'"
  check_rejected "${yaml}" "${task_name}" "registry.redhat.io/crypto-rules:latest" \
    "${SUPPORTED_REGISTRIES}"
  # A value beginning with "-" must not be read as a flag.
  check_rejected "${yaml}" "${task_name}" "-oftext/crypto-rules:latest" \
    "Unsupported rules registry '-oftext'"
  # A pullspec with no registry component must be rejected before dispatch.
  check_rejected "${yaml}" "${task_name}" "crypto-rules-image:latest" \
    "has no registry hostname"
  check_rejected "${yaml}" "${task_name}" "-oftext" \
    "has no registry hostname"

  # Graceful degradation paths must keep working.
  printf '    graceful: rules image not configured\n'
  run_step "${yaml}" "${task_name}" "" "" true
  assert_eq "exit status" 0 "${RUN_EXIT}"
  assert_eq "no image pulled" "" "${RUN_ARGV}"

  printf '    graceful: cbom generation disabled\n'
  run_step "${yaml}" "${task_name}" "" "quay.io/exd-guild-security/crypto-rules:latest" false
  assert_eq "exit status" 0 "${RUN_EXIT}"
  assert_eq "no image pulled" "" "${RUN_ARGV}"

  printf '    graceful: quay token exchange fails\n'
  STUB_TOKEN_EXCHANGE=fail \
    run_step "${yaml}" "${task_name}" "quay.io/exd-guild-security/crypto-rules:latest" "" true
  assert_eq "exit status" 0 "${RUN_EXIT}"
  assert_eq "no image pulled" "" "${RUN_ARGV}"
}

# --------------------------------------------------------------------------
# Non-divergence: the dispatch block must be identical across flavours
# --------------------------------------------------------------------------

dispatch_block() {
  # A fixed run dir for both flavours, so any difference reported is a real
  # difference in the dispatch block rather than a harness artefact.
  extract_step_script "$1" pull-rules /run-dir task \
    | awk '/^# A pullspec with no/,/^esac$/'
}

check_non_divergence() {
  printf '  non-divergence\n'
  dispatch_block "${PLAIN_YAML}" > "${WORKDIR}/block-plain"
  dispatch_block "${OCI_TA_YAML}" > "${WORKDIR}/block-oci-ta"

  CHECKS=$((CHECKS + 1))
  if [ ! -s "${WORKDIR}/block-plain" ]; then
    printf '      FAIL dispatch block not found in %s\n' "${PLAIN_YAML}"
    FAILURES=$((FAILURES + 1))
  elif diff -u "${WORKDIR}/block-plain" "${WORKDIR}/block-oci-ta" > "${WORKDIR}/block-diff"; then
    printf '      ok   dispatch block is byte-identical across flavours\n'
  else
    printf '      FAIL dispatch block diverges across flavours:\n'
    sed 's/^/        /' "${WORKDIR}/block-diff"
    FAILURES=$((FAILURES + 1))
  fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

printf 'pull-rules dispatch tests\n'
check_flavour "${PLAIN_YAML}" sast-crypto-scan
check_flavour "${OCI_TA_YAML}" sast-crypto-scan-oci-ta
check_non_divergence

printf '\n'
if [ "${FAILURES}" -eq 0 ]; then
  printf '✅ %s checks passed\n' "${CHECKS}"
  exit 0
fi

printf '❌ %s of %s checks failed\n' "${FAILURES}" "${CHECKS}"
exit 1

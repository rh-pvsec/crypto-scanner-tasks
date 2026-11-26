#!/bin/bash

EXECDIR="$(dirname $(realpath $0))"
USAGE="Usage: $0 --repo <repo_url> [--branch <branch>] [--count <number>] [--containerfile <Containerfile>] [ --secret <dockerfile.json>]"

# Created once the arguments have been validated, so that --help and the
# precondition checks below do not leave a temporary directory behind.
WORKDIR=""
# Overall deadline for a single TaskRun to reach a terminal state.
WAIT_TIMEOUT_SECONDS=3600

export SOURCE_URL=""
export TARGET_BRANCH="main"
export CONTAINERFILE="Containerfile"
export C=1
export SECRET=""

OPTS=$(getopt -o r:b:c:d:hv --long repo:,branch:,count:,containerfile:,secret:,help,verbose -n "$0" -- "$@")

if [ $? != 0 ]; then
    echo "Error processing arguments." >&2
    exit 1
fi

eval set -- "$OPTS"

while true; do
  case "$1" in
    -r | --repo )
      SOURCE_URL="$2"
      shift 2
      ;;
    -b | --branch )
      TARGET_BRANCH="$2"
      shift 2
      ;;
    -d | --containerfile )
      CONTAINERFILE="$2"
      shift 2
      ;;
    -c | --count )
      C="$2"
      shift 2
      ;;
    -s | --secret )
      SECRET="$2"
      shift 2
      ;;

    -v | --verbose )
      set -x
      shift 1
      ;;
    -h | --help )
      echo $USAGE
      exit 0
      ;;
    -- )
      shift
      break
      ;;
    * )
      break
      ;;
  esac
done

# Check mandatory argument
if [ -z "$SOURCE_URL" ]; then
  echo "Error: The argument --repo is mandatory."
  echo $USAGE
  exit 1
fi

export REVISION=$(git ls-remote -b $SOURCE_URL refs/heads/${TARGET_BRANCH} | cut -f 1)
if [ -z "$REVISION" ]; then
    echo "Error: Couldn't find the revision. Please check the url and/or specify a correct branch."
    exit 1
fi

if ! kubectl auth whoami < /dev/null &> /dev/null; then \
    echo "Please login into a k8s cluster and choose a namepace"
    exit 1
fi

export BOMBINO_URL="https://bombino.preprod.api.redhat.com/v1/sbom/quay/push"
export USER_WORKLOADS="redhat-user-workloads-stage"
if kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | grep -Eq '(^|[.-])(prd|prod)([.-]|$)'; then
  # env prod
  export BOMBINO_URL="https://bombino.api.redhat.com/v1/sbom/quay/push"
  export USER_WORKLOADS="redhat-user-workloads"
fi

export APPLICATION_NAME=tmp-application
export COMPONENT_NAME=tmp-component
export NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}')
if [ -z "$NAMESPACE" ]; then
    echo "Error: No namespace is set in the current kubectl context."
    echo "Please choose one, e.g. kubectl config set-context --current --namespace=<namespace>"
    exit 1
fi

# Only remove what we actually got as far as creating.
APP_CREATED=0
SECRET_CREATED=0
CLEANUP_DONE=0

# shellcheck disable=SC2329  # invoked indirectly by the traps installed below
cleanup() {
    # The signal handlers below exit, which fires the EXIT trap in turn, so
    # make sure the body only ever runs once.
    if [ "$CLEANUP_DONE" != 0 ]; then
        return 0
    fi
    CLEANUP_DONE=1

    if [ "$APP_CREATED" != 0 ]; then
        kubectl delete --ignore-not-found "application/${APPLICATION_NAME}"
    fi
    if [ "$SECRET_CREATED" != 0 ]; then
        kubectl delete --ignore-not-found "secret/${COMPONENT_NAME}-secret-pull"
    fi
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

# Installed before anything is created so that every exit path below -- including
# a failed PipelineRun and Ctrl-C -- releases the temporary directory and the
# cluster objects.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

WORKDIR="$(mktemp -d "/tmp/$(basename "$0").XXXX")"

# Silently remove objects in case a previous run was interrupted
kubectl delete application/tmp-application 2> /dev/null
if [ $? == 0 ]; then
    sleep 3
fi
kubectl delete secret/tmp-component-secret-pull 2> /dev/null

# populate temporary konflux objects app/component/imageregistry
APP_CREATED=1
yq '.metadata.name = env(APPLICATION_NAME), .spec.displayName = env(APPLICATION_NAME)' ${EXECDIR}/test-pipeline/application.yaml | kubectl create -f -
yq \
    '
    .metadata.name = env(COMPONENT_NAME),
    .spec.application = env(APPLICATION_NAME),
    .spec.componentName = env(COMPONENT_NAME),
    .spec.source.git.url = env(SOURCE_URL),
    .spec.source.git.revision = env(TARGET_BRANCH),
    .spec.source.git.dockerfileUrl = env(CONTAINERFILE)
    ' \
    ${EXECDIR}/test-pipeline/component.yaml | kubectl create -f -
yq \
    '
    .metadata.name = env(COMPONENT_NAME),
    .metadata.labels."appstudio.redhat.com/application" = env(APPLICATION_NAME),
    .metadata.labels."appstudio.redhat.com/component" = env(COMPONENT_NAME),
    .spec.image.name = env(NAMESPACE) + "/" + env(COMPONENT_NAME),
    .spec.notifications[].config.url = env(BOMBINO_URL)
    ' \
    ${EXECDIR}/test-pipeline/imagerepository.yaml | kubectl create -f -

if [ -n "${SECRET}" ]; then
    SECRET_CREATED=1
    kubectl create secret generic ${COMPONENT_NAME}-secret-pull --from-file=.dockerconfigjson=${SECRET} --type=kubernetes.io/dockerconfigjson
    kubectl patch serviceaccount build-pipeline-${COMPONENT_NAME} -p '{"secrets": [{"name": "tmp-component-secret-pull"}]}'
fi

export PR_FILE=component-push.yaml
cp ${EXECDIR}/test-pipeline/${PR_FILE} ${WORKDIR}/

pushd $WORKDIR > /dev/null

PR=()
# iterate over the amount of pipelines we want to trigger
for i in $(seq 1 $C); do
    export i
    # populate the pipeline definition
    yq \
        '
        .metadata.name |= sub("{{component}}", env(COMPONENT_NAME)) |
        .metadata.name += "-" + env(i) |
        .metadata.annotations."build.appstudio.openshift.io/repo" |= sub("{{revision}}", env(REVISION)) |
        .metadata.annotations."build.appstudio.redhat.com/target_branch" = env(TARGET_BRANCH) |
        .metadata.annotations."build.appstudio.redhat.com/commit_sha" = env(REVISION) |
        .metadata.labels."appstudio.openshift.io/application" = env(APPLICATION_NAME) |
        .metadata.labels."appstudio.openshift.io/component" = env(COMPONENT_NAME) |
        (.spec.params[] | select (.name == "revision") | .value ) = env(REVISION) |
        (.spec.params[] | select (.name == "git-url") | .value ) = env(SOURCE_URL) |
        (.spec.params[] | select (.name == "dockerfile") | .value ) = env(CONTAINERFILE) |
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{redhat-user-workloads}}", env(USER_WORKLOADS)) |
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{namespace}}", env(NAMESPACE)) |
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{revision}}", env(REVISION)) |
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{component}}", env(COMPONENT_NAME)) |
        del(.spec.workspaces[] | select (.name == "git-auth")) |
        del(.spec.pipelineSpec.tasks[].workspaces[] | select (.workspace == "git-auth"))
        ' \
        $PR_FILE \
        > ${PR_FILE}-$i
        PR_NAME=$(kubectl create -f ${PR_FILE}-$i -o jsonpath='{.metadata.name}')
        if [ $? != 0 ]; then
            echo "Error creating pipeline." >&2
            exit 1
        fi
        PR+=("${PR_NAME}")
done

# for each pipeline review the sast-crypto-scan taskRun status
FAILED=0
for pr in "${PR[@]}"; do
    tr="${pr}-sast-crypto-scan"
    echo "Waiting for TaskRun/${tr} to be created..."
    while sleep 1; do
        if kubectl get taskrun/${tr} -o jsonpath='{.status.conditions[0].status}' &> /dev/null; then
            break
        fi
        if [ "$(kubectl get pipelinerun/${pr} -o jsonpath='{.status.conditions[0].status}')"  == "False" ]; then
            echo "❌ pipelineRun failed!"
            exit 1
        fi

        sleep 1
    done
    echo "⏳ TaskRun initialized. Waiting for execution to finish..."
    # Poll for either terminal state rather than using
    # 'kubectl wait --for=condition=Succeeded', which only returns once the
    # condition turns True and so blocks for the whole timeout on a TaskRun
    # that has already failed.
    DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
    STATUS=""
    while true; do
        STATUS=$(kubectl get taskrun/"${tr}" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
        if [ "$STATUS" = "True" ] || [ "$STATUS" = "False" ]; then
            break
        fi
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
            echo "⌛ Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for TaskRun ${tr} to finish."
            break
        fi
        sleep 5
    done

    if [ "$STATUS" = "True" ]; then
        echo "✅ TaskRun $tr completed successfully!"
        echo taskRun Step Seconds

        # high level timing and completion stats
        # kubectl get taskrun $tr -o jsonpath='{range .status}{"Start Time: "}{.startTime}{"\n"}{"Completion Time: "}{.completionTime}{"\n"}{"Succeeded: "}{.conditions[0].status}{"\n"}{"Reason: "}{.conditions[0].reason}{"\n"}{end}'
        # step level timing and completion stats
        kubectl get taskrun $tr -o jsonpath='{range .status.steps[*]}{.name}{"\tStarted: "}{.terminated.startedAt}{"\tFinished: "}{.terminated.finishedAt}{"\n"}{end}' |
            while read line; do
                STEP=$(echo "$line" | awk '{print $1}')
                STARTED=$(echo "$line" | awk '{print $3}')
                FINISHED=$(echo "$line" | awk '{print $5}')
                # Convert to Unix epoch seconds
                START_SEC=$(date -d "$STARTED" +%s)
                END_SEC=$(date -d "$FINISHED" +%s)
                # Calculate difference
                ELAPSED=$((END_SEC - START_SEC))

                echo "$tr $STEP $ELAPSED"
            done
    else
        echo "❌ TaskRun $tr failed!"
        kubectl get taskrun/${tr} -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}'
        FAILED=1
    fi
done

popd > /dev/null

# The cluster objects and the temporary directory are removed by the EXIT trap.
# Report the overall outcome so callers can detect a failed run.
exit "$FAILED"

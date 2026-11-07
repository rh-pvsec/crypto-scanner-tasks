#!/bin/bash
#set -x
EXECDIR="$(dirname $(realpath $0))"
WORKDIR="$(mktemp -d /tmp/$(basename $0).XXXX)"
USAGE="Usage: $0 --repo <repo_url> [--branch <branch>] [--count <number>] [--containerfile <Containerfile>]"

export SOURCE_URL=""
export TARGET_BRANCH="main"
export CONTAINERFILE="Containerfile"
export C=1

OPTS=$(getopt -o r:b:c:d:h --long repo:,branch:,count:,containerfile:,help -n "$0" -- "$@")

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

# Validación del parámetro obligatorio
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

export APPLICATION_NAME=tmp-application
export COMPONENT_NAME=tmp-component
export NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}')

# remove tmp-application in case previous run was interrupted
kubectl delete application/tmp-application 2> /dev/null 
if [ $? == 0 ]; then
    sleep 3
fi

# populate temporary konflux objects app/component/imageregistry
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
    .spec.image.name = env(NAMESPACE) + "/" + env(COMPONENT_NAME)
    ' \
    ${EXECDIR}/test-pipeline/imagerepository.yaml | kubectl create -f -

export PR_FILE=component-push.yaml
cp ${EXECDIR}/test-pipeline/${PR_FILE} ${WORKDIR}/

pushd $WORKDIR > /dev/null

TR=()
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
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{namespace}}", env(NAMESPACE)) |
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{revision}}", env(REVISION)) |
        (.spec.params[] | select (.name == "output-image") | .value ) |= sub("{{component}}", env(COMPONENT_NAME)) |
        del(.spec.workspaces[] | select (.name == "git-auth")) |
        del(.spec.pipelineSpec.tasks[].workspaces[] | select (.workspace == "git-auth"))
        ' \
        $PR_FILE \
        > ${PR_FILE}-$i
        PR_NAME=$(kubectl create -f ${PR_FILE}-$i -o jsonpath='{.metadata.name}')
        PR+=("${PR_NAME}")
done

# for each pipeline review the sast-crypto-scan taskRun status
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
    kubectl wait --for=condition=Succeeded --timeout=1h taskrun/${tr}

    STATUS=$(kubectl get taskrun/${tr} -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
    echo "✅ TaskRun $tr completed successfully!"
    echo taskRun Step Seconds
    if [ "$STATUS" = "True" ]; then
        
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
    fi
done

popd > /dev/null
kubectl delete application/${APPLICATION_NAME}
rm -rf ${WORKDIR}

# Scripts and tools

## test-pull-rules.sh

Offline regression tests for the `pull-rules` step of both task flavours. No cluster is needed: the step script is extracted from each task YAML, the Tekton placeholders are pointed at temporary directories, and it runs against a stub `oc`.

It covers the `cluster-config` lookup outcomes (missing ConfigMap, unset or empty key, failed lookup, `FORCE_CBOM`), asserting whether the `warnings` marker that the `rh-crypto-scanner` step reads is written, and checks that the two flavours' scripts differ only in `WARNINGS_DIR`.

```bash
./hack/test-pull-rules.sh
```

Requires `python3` with PyYAML.

## test-pipeline.sh

This could be used to trigger n pipelines and measure timings.

As prerequisite you need to log into a test k8s or openshift environment and then run something like:

```log
$ ./test-pipeline.sh --repo=https://gitlab.cee.redhat.com/security-guild/crypto-scanning/sample/rsa-signer-c.git
application.appstudio.redhat.com/tmp-application created
component.appstudio.redhat.com/tmp-component created
imagerepository.appstudio.redhat.com/tmp-component created
Waiting for TaskRun/tmp-component-on-push-1-sast-crypto-scan to be created...
⏳ TaskRun initialized. Waiting for execution to finish...
taskrun.tekton.dev/tmp-component-on-push-1-sast-crypto-scan condition met
✅ TaskRun tmp-component-on-push-1-sast-crypto-scan completed successfully!
taskRun Step Seconds
tmp-component-on-push-1-sast-crypto-scan use-trusted-artifact 0
tmp-component-on-push-1-sast-crypto-scan pull-rules 1
tmp-component-on-push-1-sast-crypto-scan rh-crypto-scanner 9
tmp-component-on-push-1-sast-crypto-scan update-cbom-metadata 1
tmp-component-on-push-1-sast-crypto-scan upload 2
application.appstudio.redhat.com "tmp-application" deleted
```

On the 3rd column you can visualize the timings per each task step in seconds

Another example, where for accesing the base image, konflux needs to access to an authenticated registry:

```
podman login registry.redhat.io
./test-pipeline.sh  --repo=https://github.com/stackrox/stackrox.git --branch=master --containerfile=image/roxctl/konflux.Dockerfile --secret=${XDG_RUNTIME_DIR}/containers/auth.json
```
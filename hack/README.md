# Scripts and tools

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

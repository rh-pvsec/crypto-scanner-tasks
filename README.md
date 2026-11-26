# crypto-scanner-tasks

Tekton tasks for detecting cryptographic assets in source code via static analysis.

These tasks use [crypto-finder-image](https://github.com/rh-pvsec/crypto-finder-image) to scan application source and report findings in CycloneDX format (cbom.json).

## Tasks

* **[sast-crypto-scan](task/sast-crypto-scan/)** — Crypto scan task using a shared workspace.
  * published in quay.io/konflux-ci/tekton-catalog/task-sast-crypto-scan
* **[sast-crypto-scan-oci-ta](task/sast-crypto-scan-oci-ta/)** — Crypto scan task using Trusted Artifacts for source input.
  * published in quay.io/konflux-ci/tekton-catalog/task-sast-crypto-scan-oci-ta

## Usage

Include one flavor of this task by editing your pipeline (`.tekton/<component name>-pull-request.yaml` and `.tekton/<component name>-push.yaml`) and adding the following lines:

```yaml
  tasks:
    - name: sast-crypto-scan
      params:
      - name: image-digest
        value: $(tasks.build-image-index.results.IMAGE_DIGEST)
      - name: image-url
        value: $(tasks.build-image-index.results.IMAGE_URL)
      - name: SOURCE_ARTIFACT
        value: $(tasks.prefetch-dependencies.results.SOURCE_ARTIFACT)
      runAfter:
      - build-image-index
      taskRef:
        resolver: bundles
        params:
        - name: name
          value: sast-crypto-scan-oci-ta
        - name: bundle
          value: quay.io/konflux-ci/tekton-catalog/task-sast-crypto-scan-oci-ta:0.4.0
        - name: kind
          value: task
      when:
      - input: $(params.skip-checks)
        operator: in
        values:
        - "false"
```

A cbom will be uploaded as a trusted artifact when CBOM generation is enabled on the cluster (see the note below).

> [!NOTE]
> The whole scan is gated on the cluster: it runs only where `enable-cbom-generation-task` is set to `"true"` in the `cluster-config` ConfigMap of the `konflux-info` namespace, or where the task is invoked with `FORCE_CBOM=true`. On any other cluster the task reports a `SKIPPED` test output and produces no cbom. Once enabled, OpenSource rules are supported on every Konflux cluster, while ScanOSS proprietary rules are only supported on RedHat owned clusters.

## Contributing

After cloning, install the pre-commit hooks to prevent accidental secret leakage:

```bash
pip install pre-commit
pre-commit install
```

## Fullsend

This repository is enrolled in [Fullsend](https://github.com/fullsend-ai/fullsend) for automated triage, code, review, and fix workflows.

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
          value: quay.io/konflux-ci/tekton-catalog/task-sast-crypto-scan-oci-ta:0.3.1
        - name: kind
          value: task
      when:
      - input: $(params.skip-checks)
        operator: in
        values:
        - "false"
```

A cbom will be uploaded as a trusted artifact.

> [!NOTE]
> OpenSource rules are supported on every Konflux cluster, while ScanOSS proprietary rules are only supported on RedHat owned clusters.
> Which rules are used on a given cluster is decided as described in [Cluster configuration](#cluster-configuration).

## Cluster configuration

The additional (proprietary) rules are enabled per cluster through the `cluster-config` ConfigMap in the `konflux-info` namespace. The `pull-rules` step reads two keys from it:

|key|purpose|
|---|---|
|`enable-cbom-generation-task`|The additional rules image is only pulled when this is `"true"`. Any other value, an unset key, or a failed lookup makes the step skip the pull, unless `FORCE_CBOM` is `"true"`.|
|`additional-cbom-generation-rules-image`|Pullspec of the additional rules image. Used unless the `FORCE_RULES_IMAGE` parameter overrides it. When neither is set, the scan runs with the open source rules only.|

The pipeline service account therefore needs permission to `get` the `cluster-config` ConfigMap in the `konflux-info` namespace. Without that permission the lookup fails, and the task falls back to the open source rules. That fallback is silent: no warning is recorded and the task still reports `SUCCESS`, so a missing grant is indistinguishable from a fully-ruled scan in the task result.

Neither key controls whether a CBOM is produced. The scan step always runs unless `SKIP_SBOM_GENERATION` is `true`; the metadata and upload steps additionally require `image-url` and `image-digest` to be set. A CBOM is therefore still generated even when `enable-cbom-generation-task` is `false` or unset. The keys only select which rule sets the scan uses.

## Contributing

After cloning, install the pre-commit hooks to prevent accidental secret leakage:

```bash
pip install pre-commit
pre-commit install
```

## Fullsend

This repository is enrolled in [Fullsend](https://github.com/fullsend-ai/fullsend) for automated triage, code, review, and fix workflows.

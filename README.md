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
          value: quay.io/konflux-ci/tekton-catalog/task-sast-crypto-scan-oci-ta:0.3.3
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

### Cluster prerequisites for proprietary rules

Proprietary rules are selected by reading the `cluster-config` ConfigMap in the `konflux-info` namespace, so the task's service account needs `get` on that ConfigMap.

* **Lookup succeeds, key absent or empty, or the ConfigMap does not exist** — silent opt-out. The scan uses open-source rules only and the task reports `SUCCESS`.
* **Lookup fails** (an RBAC denial or an API-server error) — the task reports `result: WARNING` with `warnings: 1` and the scan falls back to open-source rules only. Granting `get` on the `cluster-config` ConfigMap in `konflux-info` restores `SUCCESS`.

## Contributing

After cloning, install the pre-commit hooks to prevent accidental secret leakage:

```bash
pip install pre-commit
pre-commit install
```

## Fullsend

This repository is enrolled in [Fullsend](https://github.com/fullsend-ai/fullsend) for automated triage, code, review, and fix workflows.

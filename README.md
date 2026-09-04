# crypto-scanner-tasks

Tekton tasks for detecting cryptographic assets in source code via static analysis.

These tasks use [crypto-finder-image](https://github.com/rh-pvsec/crypto-finder-image) to scan application source and report findings in CycloneDX format (cbom.json).

## Tasks

* **[sast-crypto-scan](task/sast-crypto-scan/)** — Crypto scan task using a shared workspace.
  * published in quay.io/konflux-ci/task-sast-crypto-scan
* **[sast-crypto-scan-oci-ta](task/sast-crypto-scan-oci-ta/)** — Crypto scan task using Trusted Artifacts for source input.
  * published in quay.io/konflux-ci/task-sast-crypto-scan-oci-ta

## Usage

Include one flavor of this task by editing your pipeline (`.tekton/<component name>-pull-request.yaml` and `.tekton/<component name>-push.yaml`) and adding the following lines:

```yaml
    - name: sast-crypto-scan
      params:
      - name: image-digest
        value: $(tasks.build-image-index.results.IMAGE_DIGEST)
      - name: image-url
        value: $(tasks.build-image-index.results.IMAGE_URL)
      - name: SOURCE_ARTIFACT
        value: $(tasks.prefetch-dependencies.results.SOURCE_ARTIFACT)
      - name: CACHI2_ARTIFACT
        value: $(tasks.prefetch-dependencies.results.CACHI2_ARTIFACT)
      taskRef:
        resolver: bundles
        params:
        - name: name
          value: sast-crypto-scan-oci-ta
        - name: bundle
          value: quay.io/konflux-ci/task-sast-crypto-scan-oci-ta:latest
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
> OpenSource rules are supported on every Konflux cluster, while proprietary rules from ScanOSS are by now supported only on the following clusters:
> - stone-stage-p01
>
> If you need to use proprietary rules on the following Red Hat clusters before it gets onboearded:
> - kflux-prd-rh03
> - kflux-prd-rh02
> - kflux-prd-rh01
> - stone-prod-p02
> - stone-prod-p01
> - kflux-ocp-p01
> - kflux-rhel-p01
> - kflux-osp-p01
> - stone-stg-rh01
> 
> please, fill a Jira in PVSEC project indicating:
> - Tenant
> - Component build service account (ex, build-pipeline-component-a)
> - OIDC provider, you can get it by runnig:
> ```
> kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
> ```

## Fullsend

This repository is enrolled in [Fullsend](https://github.com/fullsend-ai/fullsend) for automated triage, code, review, and fix workflows.

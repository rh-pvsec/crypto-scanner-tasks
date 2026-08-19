# crypto-scanner-tasks

Tekton tasks for detecting cryptographic assets in source code via static analysis.

These tasks use [crypto-finder-image](https://github.com/rh-pvsec/crypto-finder-image) to scan application source and report findings in CycloneDX format (cbom.json).

## Tasks

- **[sast-crypto-scan](task/sast-crypto-scan/)** — Crypto scan using a shared workspace.
- **[sast-crypto-scan-oci-ta](task/sast-crypto-scan-oci-ta/)** — Crypto scan using Trusted Artifacts for source input.

## Fullsend

This repository is enrolled in [Fullsend](https://github.com/fullsend-ai/fullsend) for automated triage, code, review, and fix workflows.

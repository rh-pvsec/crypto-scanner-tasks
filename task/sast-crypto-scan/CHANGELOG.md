# Changelog

<!-- Format guidelines: https://keepachangelog.com/en/1.1.0/#how -->

## 0.3.3

### Changed

- The `pull-rules` step now matches the additional rules image registry against an explicit
  allowlist (`quay.io`, `quay.io:443` and `image-registry.openshift-image-registry.svc:5000`)
  instead of treating every unrecognised host as the in-cluster registry. An unrecognised
  registry now fails with a clear message rather than silently replacing the process trust
  store with the service CA bundle, which made any other registry fail TLS verification.

### Fixed

- The `pull-rules` step now rejects an additional rules image with no registry component
  (for example `crypto-rules-image:latest`), which was previously misread as a registry
  hostname.
- The additional rules image pullspec is passed to `oc image extract` after a `--`
  terminator so that a value beginning with `-` cannot be parsed as a flag.

## 0.3.2

### Added

- `FORCE_CBOM` parameter to optionally force CBOM generation even if disabled in cluster config.
- `FORCE_RULES_IMAGE` parameter to optionally override the image used for additional proprietary CBOM rules.

### Changed

- Replaced hardcoded cluster names with dynamic configuration using the `cluster-config` ConfigMap (specifically the `enable-cbom-generation-task` and `additional-cbom-generation-rules-image` values) in the `konflux-info` namespace.

## 0.3.1

### Changed

- Tune compute resources in rh-crypto-scanner step.

## 0.3.0

### Added

- Task result "CBOM_BLOB_URL" pointing to the blob created by pushing the CBOM to the registry.

## 0.2.2

### Changed

- Add Mobster step to add required metadata to the result CBOM. The CBOM now contains PURLs
  for identifying the scanned image.

## 0.2.1

### Changed

- Update and add computeResources on every step

## 0.2.0

### Changed

- Update list of clusters with mirror of proprietary rules image

## 0.1.3

### Changed

- Use oficial crypto-scanner namespace to pull the crypto-rules-image on every staging cluster

## 0.1.2

### Changed

- Improve error handling when authenticating to quay.io using short lived token
- The task exits with a warning when the scan is expected to use proprietary rules but is unable to do so
- Manage SKIP_SBOM_GENERATION flow at script level

## 0.1.1

### Added

- Support for pulling the proprietary rules from the internal openshift registry when invoked in `stone-stage-p01`

## 0.1

### Added

- Initial release of sast-crypto-scan task
- Scans source code using crypto-finder-image with already provided open source rule sets
- It pulls proprietary rules when running in Red Hat Konflux clusters
- It uploads findings as an artifact

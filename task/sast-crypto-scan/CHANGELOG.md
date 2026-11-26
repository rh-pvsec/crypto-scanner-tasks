# Changelog

<!-- Format guidelines: https://keepachangelog.com/en/1.1.0/#how -->

## 0.3.3

### Fixed

- The `rh-crypto-scanner`, `update-cbom-metadata` and `upload` steps no longer run when
  `enable-cbom-generation-task` is not `true` in the `cluster-config` ConfigMap. Previously the
  cluster opt-out only skipped the proprietary rules, so a disabled cluster still scanned the
  source, enriched a CBOM and attached it to the image. `pull-rules` now records the opt-out and
  the remaining steps honour it, reporting a `SKIPPED` test output. `FORCE_CBOM=true` still
  bypasses the check, as its description states.

## 0.3.2

### Added

- `FORCE_CBOM` parameter to optionally force CBOM generation even if disabled in cluster config.
- `FORCE_RULES_IMAGE` parameter to optionally override the image used for additional proprietary CBOM rules.

### Changed

- Replaced hardcoded cluster names with dynamic configuration using the `cluster-config` ConfigMap (specifically the `enable-cbom-generation-task` and `additional-cbom-generation-rules-image` values) in the `konflux-info` namespace.
- Pinned the `crypto-finder-image` step image by digest instead of the mutable `latest` tag, using the `tag@sha256:` reference form already used by the other pinned images.

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

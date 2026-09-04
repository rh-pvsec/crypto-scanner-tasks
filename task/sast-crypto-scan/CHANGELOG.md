# Changelog

<!-- Format guidelines: https://keepachangelog.com/en/1.1.0/#how -->

## 0.1.1

### Added

- Support for pulling the proprietary rules from the internal openshift registry when invoked in `stone-stage-p01`

## 0.1

### Added

- Initial release of sast-crypto-scan task
- Scans source code using crypto-finder-image with already provided open source rule sets
- It pulls proprietary rules when running in Red Hat Konflux clusters
- It uploads findings as an artifact

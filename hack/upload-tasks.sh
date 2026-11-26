#!/bin/bash

podman login --get-login quay.io >/dev/null 2>&1 || podman login quay.io
tkn bundle push -f task/sast-crypto-scan-oci-ta/sast-crypto-scan-oci-ta.yaml quay.io/exd-guild-security/tekton-catalog/task-sast-crypto-scan-oci-ta:latest
tkn bundle push -f task/sast-crypto-scan/sast-crypto-scan.yaml quay.io/exd-guild-security/tekton-catalog/task-sast-crypto-scan:latest

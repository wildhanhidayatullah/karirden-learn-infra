# shellcheck shell=bash
# shellcheck disable=SC2034
# Pinned versions - single source of truth for bootstrap.sh and CI.
#
# Source this file; do not execute it directly.
#
# Static pins that cannot be sourced live elsewhere:
#   - Kubernetes node image    : kind-config.yaml
#   - Kafka / metadataVersion  : manifests/kafka-config.yaml (coupled to STRIMZI_CHART_VERSION)
#   - PostgreSQL image         : manifests/postgres.yaml (coupled to CNPG_CHART_VERSION)
#
# Container image tags for Valkey, Qdrant and SeaweedFS are not pinned here:
# they follow each chart's appVersion and therefore move with the chart version.

# Component charts
STRIMZI_CHART_VERSION=1.2.0
CNPG_CHART_VERSION=0.29.1
VALKEY_CHART_VERSION=0.12.0
QDRANT_CHART_VERSION=1.19.1
SEAWEEDFS_CHART_VERSION=4.47.0

# CI tooling
HELM_VERSION=v4.3.0
KUBECONFORM_VERSION=v0.8.0
YAMLLINT_VERSION=1.38.0
# Pinned commit of datreeio/CRDs-catalog used by kubeconform.
# A release tag (e.g. v0.0.12) lacks the Strimzi schema, so a commit SHA is required.
CRDS_CATALOG_SHA=d373c2da9702bc9509a004db83e57263fe3bdfc1

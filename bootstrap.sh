#!/usr/bin/env bash
#
# Bootstrap a local karirden-learn development environment on kind.
#
# Usage:
#   ./bootstrap.sh [--profile <name>] [--teardown] [--help]
#
# Configuration can be provided through a .env file or environment variables (see .env.example).
# The script is idempotent: it can be run repeatedly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Generated local credentials live here (git-ignored).
# Sourced before .env so that values in .env take precedence.
SECRETS_FILE="${SECRETS_FILE:-$SCRIPT_DIR/.secrets}"
if [[ -f "$SECRETS_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-karirden-learn-dev}"
NAMESPACE="${NAMESPACE:-karirden-learn-data}"
PROFILE="${PROFILE:-dev}"

# Pinned versions are authoritative and override any .env values.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/helm-repos.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

usage() {
  cat <<EOF
Bootstrap a local karirden-learn environment.

Usage: $(basename "$0") [options]

Options:
  --profile <name>   Per-component values overlay in helm-values/<name>/<component>.yaml (default: dev)
  --teardown         Delete the kind cluster and exit
  -h, --help         Show this help
EOF
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

require_kind_version() {
  local min="0.33.0"
  local current
  current="$(kind version 2>/dev/null | awk '{print $2}' | sed 's/^v//')"
  if [[ -z "$current" ]]; then
    echo "Could not determine the kind version." >&2
    exit 1
  fi
  if [[ "$(printf '%s\n%s\n' "$min" "$current" | sort -V | head -n1)" != "$min" ]]; then
    echo "kind >= v$min is required (found v$current) for the pinned Kubernetes node image." >&2
    exit 1
  fi
}

warn_on_cluster_drift() {
  local pinned actual
  pinned="$(grep -m1 -E 'image: kindest/node:' kind-config.yaml | sed -E 's/.*kindest\/node:(v[0-9.]+).*/\1/')"
  actual="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
  if [[ -n "$pinned" && -n "$actual" && "$pinned" != "$actual" ]]; then
    log "WARNING: running cluster is $actual but kind-config.yaml pins $pinned."
    log "Run './bootstrap.sh --teardown' then re-run to apply the pinned version/topology."
  fi
}

ensure_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
    log "kind cluster '$CLUSTER_NAME' already exists."
    warn_on_cluster_drift
  else
    log "Creating kind cluster '$CLUSTER_NAME'..."
    kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
    kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
  fi
}

ensure_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

generate_secret() { openssl rand -hex "$1"; }

# Generate any credential that was not provided, persist it to SECRETS_FILE
# so re-runs stay stable, and never pass secrets as command-line arguments.
resolve_credentials() {
  command -v openssl >/dev/null 2>&1 || {
    echo "openssl is required to generate local credentials." >&2
    exit 1
  }
  local var bytes generated=0
  for var in POSTGRES_PASSWORD REDIS_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY QDRANT_API_KEY; do
    if [[ -z "${!var:-}" ]]; then
      case "$var" in
        S3_ACCESS_KEY) bytes=10 ;;
        S3_SECRET_KEY) bytes=20 ;;
        *) bytes=24 ;;
      esac
      printf -v "$var" '%s' "$(generate_secret "$bytes")"
      printf '%s=%s\n' "$var" "${!var}" >> "$SECRETS_FILE"
      generated=1
    fi
  done
  if [[ "$generated" -eq 1 ]]; then
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true
    log "Generated local credentials were written to $SECRETS_FILE (git-ignored)."
  fi
}

create_encoded_secret() {
  local name="$1" key="$2" value="$3" encoded
  encoded="$(printf '%s' "$value" | base64 | tr -d '\n')"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $NAMESPACE
type: Opaque
data:
  $key: $encoded
EOF
}

create_encoded_basic_auth_secret() {
  local name="$1" username="$2" password="$3" uenc penc
  uenc="$(printf '%s' "$username" | base64 | tr -d '\n')"
  penc="$(printf '%s' "$password" | base64 | tr -d '\n')"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
data:
  username: $uenc
  password: $penc
EOF
}

create_seaweedfs_s3_secret() {
  local config
  config="$(printf '{"identities":[{"name":"admin","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$S3_ACCESS_KEY" "$S3_SECRET_KEY")"
  create_encoded_secret "karirden-learn-seaweedfs-s3" "seaweedfs_s3_config" "$config"
}

helm_deploy() {
  local release="$1" chart="$2" version="$3" values="$4" component="$5" timeout="${6:-5m}"
  local args=(upgrade --install "$release" "$chart" --version "$version"
    --namespace "$NAMESPACE" --create-namespace --wait --timeout "$timeout")
  if [[ -n "$values" && -f "$values" ]]; then
    args+=(-f "$values")
  fi
  # Per-component profile overlay: helm-values/<profile>/<component>.yaml
  local overlay="helm-values/${PROFILE}/${component}.yaml"
  if [[ -f "$overlay" ]]; then
    args+=(-f "$overlay")
  fi
  log "Deploying $release ($chart $version)..."
  helm "${args[@]}"
}

teardown() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "Deleting kind cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME"
  else
    log "kind cluster '$CLUSTER_NAME' does not exist; nothing to delete."
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --teardown) teardown; exit 0 ;;
    --profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_cmd docker kind kubectl helm
require_kind_version
resolve_credentials

ensure_cluster

# StorageClass: the kind node image ships a default "standard" class
# (rancher.io/local-path); every PVC references it explicitly.

ensure_namespace

log "Creating application secrets..."
create_encoded_basic_auth_secret "karirden-learn-postgres-app" "karirden" "$POSTGRES_PASSWORD"
create_encoded_secret "karirden-learn-valkey-auth" "default" "$REDIS_PASSWORD"
create_encoded_secret "karirden-learn-qdrant-apikey" "api-key" "$QDRANT_API_KEY"
create_seaweedfs_s3_secret

log "Adding Helm repositories..."
add_helm_repos

log "Deploying the Strimzi Kafka operator..."
helm_deploy strimzi-operator "oci://quay.io/strimzi-helm/strimzi-kafka-operator" "$STRIMZI_CHART_VERSION" "" strimzi
kubectl -n "$NAMESPACE" rollout status deployment/strimzi-cluster-operator --timeout=180s

# helm upgrade does not upgrade CRDs shipped in the chart's crds/ directory,
# so they are applied explicitly and tied to the pinned chart version.
log "Updating the Strimzi CRDs..."
helm show crds "oci://quay.io/strimzi-helm/strimzi-kafka-operator" --version "$STRIMZI_CHART_VERSION" \
  | kubectl apply --server-side --force-conflicts -f -

kubectl apply -f manifests/kafka-nodepool.yaml -n "$NAMESPACE"
kubectl apply -f manifests/kafka-config.yaml -n "$NAMESPACE"

log "Deploying the CloudNativePG operator..."
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system --create-namespace --wait --timeout 5m
kubectl apply -f manifests/postgres.yaml -n "$NAMESPACE"

helm_deploy valkey valkey/valkey "$VALKEY_CHART_VERSION" helm-values/valkey.yaml valkey
helm_deploy qdrant qdrant/qdrant "$QDRANT_CHART_VERSION" helm-values/qdrant.yaml qdrant
helm_deploy seaweedfs seaweedfs/seaweedfs "$SEAWEEDFS_CHART_VERSION" helm-values/seaweedfs.yaml seaweedfs 10m

log "Completed. Check the status of all pods with:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get pods -n cnpg-system"

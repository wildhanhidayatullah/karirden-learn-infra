# shellcheck shell=bash
# Helm repositories used by bootstrap.sh and CI.
#
# Source this file; do not execute it directly.
# Each entry is a space-separated "<repo-name> <repo-url>" pair.

HELM_REPOS=(
  "cnpg https://cloudnative-pg.github.io/charts"
  "valkey https://valkey.io/valkey-helm/"
  "qdrant https://qdrant.github.io/qdrant-helm"
  "seaweedfs https://seaweedfs.github.io/seaweedfs/helm"
)

add_helm_repos() {
  local entry name url
  for entry in "${HELM_REPOS[@]}"; do
    read -r name url <<< "$entry"
    helm repo add "$name" "$url" >/dev/null
  done
  helm repo update >/dev/null
}

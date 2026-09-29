# karirden-learn-infra

Infrastructure repository for **karirden-learn**. It provisions the local
development environment (on [kind](https://kind.sigs.k8s.io/)) and is the
starting point for a production-grade setup.

## Tech stack

| Component              | Role                               | Provisioned by                                     |
| ---------------------- | ---------------------------------- | -------------------------------------------------- |
| Kubernetes (kind)      | Local cluster, v1.36.4 (pinned)    | `kind-config.yaml`                                 |
| StorageClass           | Default `standard` class for PVCs  | Provided by the kind node image                    |
| Apache Kafka (KRaft)   | Event streaming                    | Strimzi operator + `manifests/kafka-*.yaml`        |
| PostgreSQL             | Primary relational database        | CloudNativePG operator + `manifests/postgres.yaml` |
| Valkey                 | In-memory cache (Redis-compatible) | `valkey/valkey` Helm chart                         |
| SeaweedFS              | S3-compatible object storage       | `seaweedfs/seaweedfs` Helm chart                   |
| Qdrant                 | Vector database                    | `qdrant/qdrant` Helm chart                         |

## Prerequisites

- Docker
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.33.0+
  (enforced by `bootstrap.sh`)
- kubectl
- Helm v4

## Quick start

```bash
cp .env.example .env        # adjust if needed (optional)
./bootstrap.sh              # create cluster and deploy everything
```

The script is idempotent; re-running it upgrades existing releases instead of
failing. Use a per-component overlay with `--profile <name>`: a file
`helm-values/<name>/<component>.yaml` is merged on top of that component's
defaults (no overlay files exist for `dev` yet). Overlays apply to the charts
deployed through Helm (Strimzi, Valkey, Qdrant, SeaweedFS); CloudNativePG is not
covered.

If the cluster already exists, `bootstrap.sh` warns when the running Kubernetes
version differs from the one pinned in `kind-config.yaml`; topology or image
changes require `--teardown` first.

Check the result:

```bash
kubectl get pods -n karirden-learn-data
kubectl get pods -n cnpg-system
```

Tear everything down:

```bash
./bootstrap.sh --teardown
```

## Configuration

Environment variables (via `.env` or the shell):

| Variable            | Default               | Description                                          |
| ------------------- | --------------------- | ---------------------------------------------------- |
| `CLUSTER_NAME`      | `karirden-learn-dev`  | kind cluster name                                    |
| `NAMESPACE`         | `karirden-learn-data` | Namespace for workloads                              |
| `PROFILE`           | `dev`                 | Overlay dir `helm-values/<profile>/<component>.yaml` |
| `POSTGRES_PASSWORD` | generated             | Application user password                            |
| `REDIS_PASSWORD`    | generated             | Valkey password                                      |
| `S3_ACCESS_KEY`     | generated             | SeaweedFS S3 access key                              |
| `S3_SECRET_KEY`     | generated             | SeaweedFS S3 secret key                              |
| `QDRANT_API_KEY`    | generated             | Qdrant API key                                       |

Credentials left unset are generated on the first run and persisted to
`.secrets` (git-ignored), so re-runs stay stable. Values in `.env` take
precedence over generated ones. Never reuse these in production.

Changing a credential after the first run is not automatically reconciled by
the data stores (PostgreSQL runs `initdb` only once). After editing a password,
run `./bootstrap.sh --teardown && ./bootstrap.sh` to apply it cleanly.

## Accessing the services

All services are `ClusterIP`; use `kubectl port-forward` from your machine.

| Service                 | In-cluster address                          | Port-forward                                                                                     |
| ----------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| PostgreSQL (read-write) | `karirden-learn-postgres-rw:5432`           | `kubectl -n karirden-learn-data port-forward svc/karirden-learn-postgres-rw 5432:5432`           |
| Kafka (bootstrap)       | `karirden-learn-kafka-kafka-bootstrap:9092` | `kubectl -n karirden-learn-data port-forward svc/karirden-learn-kafka-kafka-bootstrap 9092:9092` |
| Valkey                  | `valkey:6379`                               | `kubectl -n karirden-learn-data port-forward svc/valkey 6379:6379`                               |
| Qdrant HTTP / gRPC      | `qdrant:6333` / `qdrant:6334`               | `kubectl -n karirden-learn-data port-forward svc/qdrant 6333:6333`                               |
| SeaweedFS S3            | `seaweedfs-s3:8333`                         | `kubectl -n karirden-learn-data port-forward svc/seaweedfs-s3 8333:8333`                         |

Database bootstrap: database `karirden_learn`, owner `karirden`. `bootstrap.sh`
creates the `karirden-learn-postgres-app` basic-auth secret (username and
password); CloudNativePG uses it as the application secret and augments it with
connection details (`uri`, `jdbc-uri`, etc.).

### Credentials (local development)

Authentication is enabled on the data stores. Read the generated credentials
from `.secrets` or from the Kubernetes secrets:

```bash
cat .secrets                                                   # all generated values
kubectl -n karirden-learn-data get secret karirden-learn-postgres-app -o jsonpath='{.data.uri}' | base64 -d   # Postgres
kubectl -n karirden-learn-data get secret karirden-learn-valkey-auth -o jsonpath='{.data.default}' | base64 -d # Valkey
kubectl -n karirden-learn-data get secret karirden-learn-seaweedfs-s3 -o jsonpath='{.data.seaweedfs_s3_config}' | base64 -d # S3 config
kubectl -n karirden-learn-data get secret karirden-learn-qdrant-apikey -o jsonpath='{.data.api-key}' | base64 -d # Qdrant API key (the chart copies it into "qdrant-apikey")
```

## Repository layout

```
.
├── bootstrap.sh                  # idempotent setup / teardown
├── versions.sh                   # single source of truth for pinned versions
├── helm-repos.sh                 # Helm repositories, shared by bootstrap and CI
├── kind-config.yaml              # cluster topology, pinned node image
├── manifests/
│   ├── kafka-nodepool.yaml       # KafkaNodePool (KRaft, dual-role)
│   ├── kafka-config.yaml         # Kafka cluster (API v1)
│   └── postgres.yaml             # CloudNativePG Cluster
├── helm-values/
│   ├── valkey.yaml
│   ├── qdrant.yaml
│   └── seaweedfs.yaml
└── .github/workflows/ci.yml
```

## Design decisions

- **Kubernetes version pinned by digest** so every run is reproducible.
  `kindest/node:v1.36.4` is within Strimzi 1.2.0's tested range (1.30-1.36).
- **Storage uses the `standard` class provided by kind** (Rancher
  local-path-provisioner). PVCs reference it explicitly rather than relying on
  the cluster default, and no extra provisioner is installed.
- **Kafka runs in KRaft mode** (no ZooKeeper). Apache Kafka 4.x only supports
  KRaft, and Strimzi 1.x only accepts CRD API `v1`.
- **CloudNativePG** replaces the Bitnami PostgreSQL chart, which no longer
  receives updates (Bitnami's public catalog was retired in 2025).
- **Valkey** replaces Bitnami Redis. It is BSD-licensed, Redis-compatible, and
  maintained by the Linux Foundation.
- **Strimzi is installed from its OCI chart**
  (`oci://quay.io/strimzi-helm/strimzi-kafka-operator`) because the legacy
  `strimzi.io/charts` Helm repository is deprecated.
- **Stateful workloads use PVCs** so data survives pod restarts.
- **Data stores require authentication** (Valkey ACL, SeaweedFS S3, Qdrant API
  key). Credentials are generated once and persisted to a git-ignored
  `.secrets` file; they are never passed as command-line arguments.
- **Container images for tooling are pinned by digest** (Kubernetes node and
  PostgreSQL) for reproducibility.

## Version pinning and upgrades

All chart and CI tooling versions live in **`versions.sh`**, the single source
of truth sourced by both `bootstrap.sh` and the CI workflow. To bump a version,
edit `versions.sh` only. Its values are authoritative and override any `.env`
settings.

One caveat: Strimzi ships its CRDs in the chart's `crds/` directory, which
`helm upgrade` does **not** upgrade. `bootstrap.sh` therefore applies the
version-matched CRDs explicitly (`helm show crds … | kubectl apply --server-side`).
Bumping `STRIMZI_CHART_VERSION` is still the only edit, but this CRD step is what
keeps them in sync.

Three pins are static because they cannot be sourced at runtime:

- Kubernetes node image in `kind-config.yaml`
- Kafka `version`/`metadataVersion` in `manifests/kafka-config.yaml`, which is
  coupled to the pinned Strimzi chart version
- PostgreSQL image in `manifests/postgres.yaml`, pinned by tag and digest and
  coupled to the CNPG operator default

Container image tags for Valkey, Qdrant, and SeaweedFS are intentionally not
pinned separately: they follow each chart's `appVersion` and therefore move with
the chart version.

For convenience, the current component pins are listed below. `versions.sh` is
the authoritative source; this list is illustrative.

- Strimzi `1.2.0`
- CloudNativePG `0.29.1`
- Valkey `0.12.0`
- Qdrant `1.19.1`
- SeaweedFS `4.47.0`
- Kubernetes `1.36.4`
- PostgreSQL `18.4`

## Continuous integration

`.github/workflows/ci.yml` runs on changes to scripts, manifests, and values:

- `bash -n` and ShellCheck on `bootstrap.sh`, `versions.sh`, `helm-repos.sh`
- yamllint (pinned) on YAML
- a check that `README.md` lists every pinned chart version from `versions.sh`
- kubeconform on `manifests/`, using a SHA-pinned CRDs-catalog for Strimzi and
  CloudNativePG schemas
- `helm template` rendering of every chart used by `bootstrap.sh`, validated
  with kubeconform (CRD resources skipped)

`helm test` is not run, so the charts' own test hooks are not exercised.

## Roadmap to production

This repository currently targets a local, resource-conscious development
profile. The next steps toward production are: GitOps (Argo CD/Flux),
managed secrets (Sealed Secrets / External Secrets), HA replica counts,
backups (Barman Cloud for PostgreSQL), and observability.

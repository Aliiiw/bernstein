# Bernstein — Poll Application on Kubernetes

End-to-end automated deployment of the multi-service **Poll** application onto a Kubernetes cluster, including container builds, private Docker registry publishing, persistent PostgreSQL storage, health probes, PodDisruptionBudgets, and verified zero-downtime rolling updates.

## Architecture

```text
Browser ──► Poll (Flask, :80) ──► Redis 8 (:6379) ──► Worker (Java 25) ──► PostgreSQL 18 (:5432) ◄── Result (Node.js, :80) ◄── Browser
```

| Service | Runtime | K8s Workload | Replicas | Exposure |
| :--- | :--- | :--- | :---: | :--- |
| `poll` | Python 3.14 (Flask + Gunicorn) | `Deployment` | 2 | `LoadBalancer` (`:8080 -> :80`) |
| `worker` | Java 25 (Maven multi-stage) | `Deployment` | 2 | None (background consumer) |
| `result` | Node.js 24 (Express + Socket.IO) | `Deployment` | 2 | `LoadBalancer` (`:8081 -> :80`) |
| `redis` | Redis 8 Alpine | `Deployment` | 1 | `ClusterIP` (`:6379`) |
| `postgres` | PostgreSQL 18 Alpine | `StatefulSet` + `PVC (1Gi)` | 1 | `ClusterIP` (`:5432`) |

## Project Structure

```text
.
├── poll-application/        # Source code, Dockerfiles, and schema.sql
├── k8s/
│   ├── 00-namespace.yaml    # Dedicated poll-app namespace
│   ├── 01-configmap.yaml    # Non-sensitive app config & schema.sql init ConfigMap
│   ├── 02-redis.yaml        # Redis Deployment + ClusterIP Service
│   ├── 03-postgres.yaml     # PostgreSQL StatefulSet + PVC + ClusterIP Service
│   ├── 04-poll.yaml         # Poll Deployment + LoadBalancer Service
│   ├── 05-worker.yaml       # Worker Deployment
│   ├── 06-result.yaml       # Result Deployment + LoadBalancer Service
│   └── 07-pdb.yaml          # PodDisruptionBudgets for poll, worker, and result
├── scripts/
│   └── deploy.sh            # End-to-end build, push, secret injection, and deploy script
├── docker-compose.yml       # Optional local Docker Compose setup for quick dev testing
├── .env.example             # Template for required credentials and deployment variables
└── README.md
```

## Prerequisites

- **Docker** (with access to a private container registry, e.g., GitHub Container Registry `ghcr.io`, Azure Container Registry, or AWS ECR)
- **kubectl** configured to point at your target Kubernetes cluster (e.g., AKS, EKS, GKE, DigitalOcean Kubernetes, or Docker Desktop Kubernetes)
- **Bash** (`scripts/deploy.sh`)

## Configuration (Credentials & Secrets)

Credentials and passwords are **never committed** to this repository. Before deploying:

1. Copy the environment template:
   ```bash
   cp .env.example .env
   ```
2. Edit `.env` and set your own values:
   - `REGISTRY`: Base image path in your private registry (e.g., `ghcr.io/<your-username>` or `<your-acr>.azurecr.io`)
   - `REGISTRY_SERVER`: Registry hostname for login (e.g., `ghcr.io`)
   - `REGISTRY_USER`: Registry username
   - `REGISTRY_PASSWORD`: Personal Access Token / password with `read:packages` and `write:packages` permissions
   - `IMAGE_TAG`: Tag to build and deploy (default: `v1`)
   - `POSTGRES_PASSWORD`: Password for PostgreSQL
   - `REDIS_PASSWORD`: Password for Redis (`--requirepass`)

> `.env` is listed in `.gitignore` and will never be tracked by Git. During deployment, `scripts/deploy.sh` injects `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, and registry credentials directly into Kubernetes `Secret` objects (`poll-secrets` and `ghcr-secret`).

## Deployment from Scratch

Run the automated deployment script:

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

If you are building from an Apple Silicon Mac (`arm64`) and deploying to an `amd64` cloud cluster (such as AKS/EKS/GKE), specify the target platform:

```bash
DOCKER_PLATFORM=linux/amd64 ./scripts/deploy.sh
```

The script executes the full pipeline in order:
1. Logs in to the private Docker registry.
2. Builds and pushes `poll`, `worker`, and `result` images with `IMAGE_TAG`.
3. Applies the `poll-app` namespace, ConfigMaps (`poll-config` and `postgres-init-sql`), and idempotently creates/updates `poll-secrets` and `ghcr-secret`.
4. Deploys Redis, PostgreSQL (`StatefulSet` + `1Gi` PVC), PDBs, and the 3 application services.
5. Waits for all rollouts to complete and prints pod & service statuses.

## Accessing the Application

- **On a Cloud Kubernetes Cluster (AKS / EKS / GKE / DigitalOcean):**
  Check the external IPs assigned to the `LoadBalancer` services:
  ```bash
  kubectl get svc -n poll-app
  ```
  - Poll page: `http://<POLL_EXTERNAL_IP>:8080`
  - Result page: `http://<RESULT_EXTERNAL_IP>:8081`

- **On Local Docker Desktop Kubernetes:**
  Use port-forwarding to reach the services locally:
  ```bash
  kubectl port-forward -n poll-app svc/poll 8080:8080 &
  kubectl port-forward -n poll-app svc/result 8081:8081 &
  ```
  - Poll page: `http://localhost:8080`
  - Result page: `http://localhost:8081`

## Zero-Downtime Update

After modifying the source code of any service (for example `poll`), deploy a new version with zero downtime by bumping `IMAGE_TAG`:

```bash
IMAGE_TAG=v2 ./scripts/deploy.sh
```

You can verify zero dropped requests during the rollout by running a continuous requester in another terminal:

```bash
kubectl run curl-test --rm -it --image=curlimages/curl -n poll-app -- \
  sh -c 'while true; do curl -s -o /dev/null -w "%{http_code} " http://poll:8080/; sleep 0.2; done'
```

## Technical Choices & Best Practices

- **Dedicated Namespace (`poll-app`):** Isolates all application resources from `default` and simplifies lifecycle management and teardown.
- **StatefulSet + PVC for PostgreSQL:** Guarantees a stable pod identity (`postgres-0`), persistent storage (`/var/lib/postgresql`), and prevents concurrent writes to the same data directory. `schema.sql` is mounted read-only from a `ConfigMap` into `/docker-entrypoint-initdb.d`.
- **Internal vs. External Services:** `redis` and `postgres` use `ClusterIP` (unreachable from the internet), while only `poll` and `result` are exposed via `LoadBalancer`. `worker` has no Service as it only consumes from Redis and writes to PostgreSQL.
- **True Zero-Downtime Rolling Updates:** `poll`, `worker`, and `result` run with `replicas: 2`, `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`), HTTP `livenessProbe` (`/healthz`), HTTP `readinessProbe` (`/readyz`), and a `preStop` lifecycle hook (`sleep 5`) on HTTP services to avoid the async race condition between `SIGTERM` and `kube-proxy` endpoint updates.
- **Resilience Against Node Maintenance (`kubectl drain`):** `PodDisruptionBudget` (`minAvailable: 1`) on `poll`, `worker`, and `result` ensures at least one healthy replica remains available during voluntary node evictions.
- **Resource Requests & Limits:** Every container defines CPU and memory `requests` and `limits` to prevent noisy-neighbor resource exhaustion (e.g., limiting Redis CPU/RAM).
- **Secrets Management:** Passwords and registry credentials are injected at deploy time into Kubernetes `Secret`s and never stored in Git.

## Cleanup

To remove the entire deployment from the cluster:

```bash
kubectl delete namespace poll-app
```

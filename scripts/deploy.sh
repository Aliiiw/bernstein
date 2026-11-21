#!/usr/bin/env bash
set -euo pipefail

OVERRIDE_TAG="${IMAGE_TAG:-}"

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

if [ -n "$OVERRIDE_TAG" ]; then
  IMAGE_TAG="$OVERRIDE_TAG"
fi

IMAGE_TAG="${IMAGE_TAG:-v1}"

for var in REGISTRY REGISTRY_SERVER REGISTRY_USER REGISTRY_PASSWORD POSTGRES_PASSWORD REDIS_PASSWORD; do
  if [ -z "${!var:-}" ]; then
    echo "Error: $var is not set. Check your .env file." >&2
    exit 1
  fi
done

echo "[1/5] Logging in to private registry ($REGISTRY_SERVER)..."
echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_SERVER" -u "$REGISTRY_USER" --password-stdin

echo "[2/5] Building and pushing images (tag: $IMAGE_TAG)..."
for service in poll worker result; do
  IMAGE="${REGISTRY}/bernstein-${service}:${IMAGE_TAG}"
  if [ -n "${DOCKER_PLATFORM:-}" ]; then
    docker build --platform "$DOCKER_PLATFORM" -t "$IMAGE" "./poll-application/${service}"
  else
    docker build -t "$IMAGE" "./poll-application/${service}"
  fi
  docker push "$IMAGE"
done

echo "[3/5] Applying namespace, configmaps, and secrets..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-configmap.yaml

kubectl create secret generic poll-secrets \
  -n poll-app \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry ghcr-secret \
  -n poll-app \
  --docker-server="$REGISTRY_SERVER" \
  --docker-username="$REGISTRY_USER" \
  --docker-password="$REGISTRY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[4/5] Deploying services and PDBs..."
kubectl apply -f k8s/02-redis.yaml
kubectl apply -f k8s/03-postgres.yaml
kubectl apply -f k8s/07-pdb.yaml

for manifest in k8s/04-poll.yaml k8s/05-worker.yaml k8s/06-result.yaml; do
  sed "s|ghcr.io/aliiiw|${REGISTRY}|g; s|:v1|:${IMAGE_TAG}|g" "$manifest" | kubectl apply -f -
done

echo "[5/5] Waiting for rollouts to complete..."
kubectl rollout status deployment/redis -n poll-app
kubectl rollout status statefulset/postgres -n poll-app
kubectl rollout status deployment/poll -n poll-app
kubectl rollout status deployment/worker -n poll-app
kubectl rollout status deployment/result -n poll-app

echo "Deployment complete!"
kubectl get pods,svc -n poll-app
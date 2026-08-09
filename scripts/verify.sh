#!/usr/bin/env bash
# Verification helpers for local Docker, Docker Hub, and ECS.
# Usage examples:
#   ./scripts/verify.sh local
#   ./scripts/verify.sh hub
#   ./scripts/verify.sh ecs
#   ./scripts/verify.sh all

set -euo pipefail

APP_PORT="${APP_PORT:-5000}"
IMAGE_LOCAL="${IMAGE_LOCAL:-final-python:local}"

cmd_local() {
  echo "==> Building local image ${IMAGE_LOCAL}"
  docker build -t "$IMAGE_LOCAL" .

  echo "==> Running container smoke test"
  CID=$(docker run -d --rm -p "${APP_PORT}:5000" --name final-python-verify "$IMAGE_LOCAL")
  cleanup() { docker stop "$CID" >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  echo "==> Waiting for /health"
  for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
      echo "OK: container healthy"
      curl -fsS "http://127.0.0.1:${APP_PORT}/health"
      echo
      curl -fsS -o /dev/null -w "Swagger /api/doc HTTP %{http_code}\n" \
        "http://127.0.0.1:${APP_PORT}/api/doc"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: container did not become healthy"
  docker logs "$CID" || true
  exit 1
}

cmd_hub() {
  : "${DOCKERHUB_USERNAME:?Set DOCKERHUB_USERNAME}"
  : "${DOCKERHUB_REPOSITORY:?Set DOCKERHUB_REPOSITORY}"
  : "${DOCKERHUB_TOKEN:?Set DOCKERHUB_TOKEN}"

  REPO="${DOCKERHUB_USERNAME}/${DOCKERHUB_REPOSITORY}"
  echo "==> Checking Docker Hub tags for ${REPO}"
  TOKEN=$(curl -sS -u "${DOCKERHUB_USERNAME}:${DOCKERHUB_TOKEN}" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" \
    | jq -r .token)

  for TAG in latest ${IMAGE_TAG:-}; do
    [ -z "$TAG" ] && continue
    CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${TOKEN}" \
      "https://registry-1.docker.io/v2/${REPO}/manifests/${TAG}")
    if [ "$CODE" = "200" ]; then
      echo "OK: ${REPO}:${TAG}"
    else
      echo "MISSING: ${REPO}:${TAG} (HTTP ${CODE})"
      exit 1
    fi
  done
}

cmd_ecs() {
  : "${AWS_REGION:?Set AWS_REGION}"
  : "${ECS_CLUSTER:?Set ECS_CLUSTER}"
  : "${ECS_SERVICE:?Set ECS_SERVICE}"

  echo "==> ECS service status"
  aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --query 'services[0].{status:status,running:runningCount,desired:desiredCount,taskDef:taskDefinition}' \
    --output table

  echo "==> Running tasks"
  TASK_ARNS=$(aws ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
    --desired-status RUNNING --region "$AWS_REGION" --query 'taskArns' --output text)
  if [ -z "$TASK_ARNS" ] || [ "$TASK_ARNS" = "None" ]; then
    echo "ERROR: no running tasks"
    exit 1
  fi
  aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks $TASK_ARNS --region "$AWS_REGION" \
    --query 'tasks[].{arn:taskArn,lastStatus:lastStatus,health:healthStatus,image:containers[0].image}' \
    --output table

  if [ -n "${ALB_DNS:-}" ]; then
    echo "==> Hitting application via ALB"
    curl -fsS "http://${ALB_DNS}/health"
    echo
    curl -fsS -o /dev/null -w "Swagger /api/doc HTTP %{http_code}\n" "http://${ALB_DNS}/api/doc"
  else
    echo "(Set ALB_DNS to also probe the load balancer URL)"
  fi
}

usage() {
  echo "Usage: $0 {local|hub|ecs|all}"
  exit 1
}

case "${1:-}" in
  local) cmd_local ;;
  hub) cmd_hub ;;
  ecs) cmd_ecs ;;
  all)
    cmd_local
    cmd_hub
    cmd_ecs
    ;;
  *) usage ;;
esac

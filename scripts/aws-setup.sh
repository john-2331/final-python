#!/usr/bin/env bash
# One-time AWS bootstrap for final-python on ECS EC2 + ALB.
# To ensure an EC2 container instance and EC2 launch-type service exist, also run:
#   ./scripts/migrate-to-ecs-ec2.sh
# Prerequisites: AWS CLI v2 configured, jq installed, sufficient IAM permissions.
# Does NOT use Amazon ECR — the container image comes from Docker Hub.
#
# Usage:
#   export AWS_PROFILE=john
#   export AWS_REGION=us-east-1
#   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
#   export DOCKERHUB_USERNAME=your-dockerhub-user
#   export DOCKERHUB_REPOSITORY=final-python
#   export GITHUB_ORG=your-github-user-or-org
#   export GITHUB_REPO=final-python
#   ./scripts/aws-setup.sh
#
# Optional private Docker Hub pull:
#   export DOCKERHUB_TOKEN=...   # Hub access token
#   (script stores credentials in Secrets Manager for the task execution role)

set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION}"
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${DOCKERHUB_USERNAME:?Set DOCKERHUB_USERNAME}"
: "${DOCKERHUB_REPOSITORY:?Set DOCKERHUB_REPOSITORY}"
: "${GITHUB_ORG:?Set GITHUB_ORG (GitHub user or org that owns the repo)}"
: "${GITHUB_REPO:?Set GITHUB_REPO}"

APP_NAME="${APP_NAME:-final-python}"
CLUSTER_NAME="${CLUSTER_NAME:-${APP_NAME}-cluster}"
SERVICE_NAME="${SERVICE_NAME:-${APP_NAME}-service}"
TASK_FAMILY="${TASK_FAMILY:-${APP_NAME}}"
CONTAINER_NAME="${CONTAINER_NAME:-${APP_NAME}}"
LOG_GROUP="${LOG_GROUP:-/ecs/${APP_NAME}}"
EXEC_ROLE_NAME="${EXEC_ROLE_NAME:-ecsTaskExecutionRole}"
TASK_ROLE_NAME="${TASK_ROLE_NAME:-${APP_NAME}TaskRole}"
GITHUB_OIDC_ROLE_NAME="${GITHUB_OIDC_ROLE_NAME:-GitHubActionsECSDeployRole}"
IMAGE_URI="${DOCKERHUB_USERNAME}/${DOCKERHUB_REPOSITORY}:latest"

echo "==> Region=${AWS_REGION} Account=${AWS_ACCOUNT_ID}"
echo "==> Image=${IMAGE_URI}"

# ---------------------------------------------------------------------------
# VPC / networking (default VPC for course simplicity; customize for prod VPCs)
# ---------------------------------------------------------------------------
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "ERROR: No default VPC found. Set VPC_ID / SUBNET_IDS manually."
  exit 1
fi

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].SubnetId' --output text --region "$AWS_REGION")
SUBNET_1=$(echo "$SUBNET_IDS" | awk '{print $1}')
SUBNET_2=$(echo "$SUBNET_IDS" | awk '{print $2}')
if [ -z "$SUBNET_1" ] || [ -z "$SUBNET_2" ]; then
  echo "ERROR: Need at least 2 subnets in VPC ${VPC_ID} for an internet-facing ALB"
  exit 1
fi
echo "==> VPC=${VPC_ID} Subnets=${SUBNET_1},${SUBNET_2}"

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" = "None" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-alb-sg" \
    --description "ALB SG for ${APP_NAME}" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$AWS_REGION")
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$AWS_REGION" || true
fi

TASK_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-task-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$TASK_SG_ID" ] || [ "$TASK_SG_ID" = "None" ]; then
  TASK_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-task-sg" \
    --description "ECS tasks SG for ${APP_NAME}" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$AWS_REGION")
  aws ec2 authorize-security-group-ingress --group-id "$TASK_SG_ID" \
    --protocol tcp --port 5000 --source-group "$ALB_SG_ID" --region "$AWS_REGION" || true
fi
echo "==> ALB SG=${ALB_SG_ID} Task SG=${TASK_SG_ID}"

# ---------------------------------------------------------------------------
# CloudWatch Logs
# ---------------------------------------------------------------------------
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || true

# ---------------------------------------------------------------------------
# IAM: task execution role + task role
# ---------------------------------------------------------------------------
create_role_if_missing() {
  local role_name="$1"
  local trust_policy="$2"
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "$trust_policy" >/dev/null
  fi
}

ECS_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

create_role_if_missing "$EXEC_ROLE_NAME" "$ECS_TRUST"
aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1 || true

create_role_if_missing "$TASK_ROLE_NAME" "$ECS_TRUST"

# Optional: private Docker Hub credentials for ECS image pulls
if [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  SECRET_NAME="${APP_NAME}/dockerhub"
  SECRET_STRING=$(jq -n \
    --arg u "$DOCKERHUB_USERNAME" \
    --arg p "$DOCKERHUB_TOKEN" \
    '{username:$u,password:$p}')
  if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" \
      --secret-string "$SECRET_STRING" --region "$AWS_REGION" >/dev/null
  else
    aws secretsmanager create-secret --name "$SECRET_NAME" \
      --secret-string "$SECRET_STRING" --region "$AWS_REGION" >/dev/null
  fi
  SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
    --query ARN --output text --region "$AWS_REGION")
  cat > /tmp/${APP_NAME}-exec-extra.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": ["${SECRET_ARN}"]
  }]
}
EOF
  aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" \
    --policy-name DockerHubSecretAccess \
    --policy-document "file:///tmp/${APP_NAME}-exec-extra.json"
  REPOSITORY_CREDENTIALS_ARN="$SECRET_ARN"
else
  REPOSITORY_CREDENTIALS_ARN=""
  echo "==> DOCKERHUB_TOKEN not set; assuming public Docker Hub image"
fi

# ---------------------------------------------------------------------------
# IAM: GitHub OIDC provider + deploy role
# ---------------------------------------------------------------------------
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_ARN=$(aws iam list-open-id-connect-providers --query \
  "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
  --output text)
if [ -z "$OIDC_ARN" ] || [ "$OIDC_ARN" = "None" ]; then
  # Thumbprint for GitHub Actions OIDC (AWS also validates the cert chain)
  OIDC_ARN=$(aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
    --query OpenIDConnectProviderArn --output text)
fi

GITHUB_TRUST=$(jq -n \
  --arg account "$AWS_ACCOUNT_ID" \
  --arg org "$GITHUB_ORG" \
  --arg repo "$GITHUB_REPO" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Federated: ("arn:aws:iam::" + $account + ":oidc-provider/token.actions.githubusercontent.com") },
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        StringLike: {
          "token.actions.githubusercontent.com:sub": ("repo:" + $org + "/" + $repo + ":*")
        }
      }
    }]
  }')

create_role_if_missing "$GITHUB_OIDC_ROLE_NAME" "$GITHUB_TRUST"
# Update trust in case org/repo changed
aws iam update-assume-role-policy --role-name "$GITHUB_OIDC_ROLE_NAME" \
  --policy-document "$GITHUB_TRUST"

cat > /tmp/${APP_NAME}-gha-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECSDeploy",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRolesToECS",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EXEC_ROLE_NAME}",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${TASK_ROLE_NAME}"
      ]
    }
  ]
}
EOF
aws iam put-role-policy --role-name "$GITHUB_OIDC_ROLE_NAME" \
  --policy-name ECSDeployPolicy \
  --policy-document "file:///tmp/${APP_NAME}-gha-policy.json"

GITHUB_ROLE_ARN=$(aws iam get-role --role-name "$GITHUB_OIDC_ROLE_NAME" --query Role.Arn --output text)

# ---------------------------------------------------------------------------
# ALB + target group + listener
# ---------------------------------------------------------------------------
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${APP_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${APP_NAME}-alb" \
    --subnets "$SUBNET_1" "$SUBNET_2" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$AWS_REGION")
fi

TG_ARN=$(aws elbv2 describe-target-groups --names "${APP_NAME}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${APP_NAME}-tg" \
    --protocol HTTP \
    --port 5000 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region "$AWS_REGION")
fi

LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].ListenerArn' --output text --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --region "$AWS_REGION" >/dev/null
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$AWS_REGION")

# ---------------------------------------------------------------------------
# ECS cluster, task definition, service
# ---------------------------------------------------------------------------
aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true

EXEC_ROLE_ARN=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" --query Role.Arn --output text)
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query Role.Arn --output text)

# Build task definition from template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_TD=$(mktemp)
jq \
  --arg family "$TASK_FAMILY" \
  --arg exec "$EXEC_ROLE_ARN" \
  --arg task "$TASK_ROLE_ARN" \
  --arg image "$IMAGE_URI" \
  --arg cname "$CONTAINER_NAME" \
  --arg region "$AWS_REGION" \
  --arg loggroup "$LOG_GROUP" \
  '
  .family = $family
  | .executionRoleArn = $exec
  | .taskRoleArn = $task
  | .containerDefinitions[0].name = $cname
  | .containerDefinitions[0].image = $image
  | .containerDefinitions[0].logConfiguration.options["awslogs-group"] = $loggroup
  | .containerDefinitions[0].logConfiguration.options["awslogs-region"] = $region
  ' \
  "${ROOT_DIR}/ecs/task-definition.json" > "$TMP_TD"

if [ -n "$REPOSITORY_CREDENTIALS_ARN" ]; then
  jq --arg arn "$REPOSITORY_CREDENTIALS_ARN" \
    '.containerDefinitions[0].repositoryCredentials = {credentialsParameter: $arn}' \
    "$TMP_TD" > "${TMP_TD}.creds" && mv "${TMP_TD}.creds" "$TMP_TD"
fi

aws ecs register-task-definition \
  --cli-input-json "file://${TMP_TD}" \
  --region "$AWS_REGION" >/dev/null

SERVICE_EXISTS=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text --region "$AWS_REGION" 2>/dev/null || true)

if [ -z "$SERVICE_EXISTS" ] || [ "$SERVICE_EXISTS" = "None" ]; then
  echo "==> NOTE: create-service with EC2 requires a registered container instance."
  echo "==> Run ./scripts/migrate-to-ecs-ec2.sh to launch the EC2 instance and create the EC2 service."
else
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --task-definition "$TASK_FAMILY" \
    --force-new-deployment \
    --region "$AWS_REGION" >/dev/null || true
fi

rm -f "$TMP_TD"

cat <<EOF

========================================================================
AWS base setup complete (Docker Hub + ECS — no ECR)
========================================================================
Cluster:              ${CLUSTER_NAME}
Task definition:      ${TASK_FAMILY}
Container name:       ${CONTAINER_NAME}
Image:                ${IMAGE_URI}
Log group:            ${LOG_GROUP}
ALB DNS:              http://${ALB_DNS}
GitHub OIDC role ARN: ${GITHUB_ROLE_ARN}

Next (required for Part C — ECS + one EC2 instance):
  ./scripts/migrate-to-ecs-ec2.sh

Configure these GitHub repository secrets:
  DOCKERHUB_USERNAME      = ${DOCKERHUB_USERNAME}
  DOCKERHUB_TOKEN         = <Docker Hub access token>
  DOCKERHUB_REPOSITORY    = ${DOCKERHUB_REPOSITORY}
  AWS_REGION              = ${AWS_REGION}
  AWS_ROLE_ARN             = ${GITHUB_ROLE_ARN}
  AWS_ACCESS_KEY_ID       = <IAM access key>
  AWS_SECRET_ACCESS_KEY   = <IAM secret key>
  ECS_CLUSTER             = ${CLUSTER_NAME}
  ECS_SERVICE             = ${SERVICE_NAME}
  ECS_TASK_DEFINITION     = ${TASK_FAMILY}
  CONTAINER_NAME          = ${CONTAINER_NAME}

App URLs after EC2 migration:
  http://${ALB_DNS}/api/doc
  http://${ALB_DNS}/health
========================================================================
EOF

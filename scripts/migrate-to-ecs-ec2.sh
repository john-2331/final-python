#!/usr/bin/env bash
# Ensure final-python runs on ECS with EC2 launch type (one container instance).
# Course Part C: "deploy ECS and one EC2 instance on AWS".
#
# Usage:
#   export AWS_PROFILE=john
#   export AWS_REGION=us-east-1
#   export AWS_ACCOUNT_ID=139830186794
#   export DOCKERHUB_USERNAME=john2331
#   export DOCKERHUB_REPOSITORY=final-python
#   ./scripts/migrate-to-ecs-ec2.sh

set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION}"
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${DOCKERHUB_USERNAME:?Set DOCKERHUB_USERNAME}"
: "${DOCKERHUB_REPOSITORY:?Set DOCKERHUB_REPOSITORY}"

APP_NAME="${APP_NAME:-final-python}"
CLUSTER_NAME="${CLUSTER_NAME:-${APP_NAME}-cluster}"
SERVICE_NAME="${SERVICE_NAME:-${APP_NAME}-service}"
TASK_FAMILY="${TASK_FAMILY:-${APP_NAME}}"
CONTAINER_NAME="${CONTAINER_NAME:-${APP_NAME}}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
KEY_NAME="${KEY_NAME:-}"   # optional SSH key pair name
IMAGE_URI="${DOCKERHUB_USERNAME}/${DOCKERHUB_REPOSITORY}:latest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Migrating ${APP_NAME} to ECS EC2 launch type"
echo "==> Cluster=${CLUSTER_NAME} Image=${IMAGE_URI}"

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].SubnetId' --output text --region "$AWS_REGION")
SUBNET_1=$(echo "$SUBNET_IDS" | awk '{print $1}')
SUBNET_2=$(echo "$SUBNET_IDS" | awk '{print $2}')

ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")
TASK_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-task-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")
TG_ARN=$(aws elbv2 describe-target-groups --names "${APP_NAME}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$AWS_REGION")

echo "==> VPC=${VPC_ID} Subnet=${SUBNET_1} ALB_SG=${ALB_SG_ID} TASK_SG=${TASK_SG_ID}"

# ---------------------------------------------------------------------------
# IAM: ECS EC2 instance role + instance profile
# ---------------------------------------------------------------------------
INSTANCE_ROLE_NAME="${APP_NAME}EcsInstanceRole"
INSTANCE_PROFILE_NAME="${APP_NAME}EcsInstanceProfile"
ECS_INSTANCE_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

if ! aws iam get-role --role-name "$INSTANCE_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$INSTANCE_ROLE_NAME" \
    --assume-role-policy-document "$ECS_INSTANCE_TRUST" >/dev/null
fi
aws iam attach-role-policy --role-name "$INSTANCE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role >/dev/null 2>&1 || true
aws iam attach-role-policy --role-name "$INSTANCE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true

if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$INSTANCE_ROLE_NAME" >/dev/null
  echo "==> Waiting for instance profile propagation..."
  sleep 15
fi

# ---------------------------------------------------------------------------
# Security group for the EC2 container instance
# ---------------------------------------------------------------------------
EC2_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-ec2-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || true)
if [ -z "$EC2_SG_ID" ] || [ "$EC2_SG_ID" = "None" ]; then
  EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-ec2-sg" \
    --description "ECS EC2 container instance SG for ${APP_NAME}" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$AWS_REGION")
fi
# No inbound SSH required — manage via SSM (AmazonSSMManagedInstanceCore on instance role).

# ---------------------------------------------------------------------------
# Launch one ECS-optimized EC2 instance into the cluster
# ---------------------------------------------------------------------------
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id \
  --query 'Parameters[0].Value' --output text --region "$AWS_REGION")
echo "==> ECS-optimized AMI=${AMI_ID}"

# Reuse existing tagged instance if already running
EXISTING_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${APP_NAME}-ecs-ec2" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION" 2>/dev/null || true)

USER_DATA=$(base64 <<EOF
#!/bin/bash
echo ECS_CLUSTER=${CLUSTER_NAME} >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_ENI=true >> /etc/ecs/ecs.config
EOF
)

if [ -z "$EXISTING_INSTANCE" ] || [ "$EXISTING_INSTANCE" = "None" ]; then
  RUN_ARGS=(
    --image-id "$AMI_ID"
    --instance-type "$INSTANCE_TYPE"
    --subnet-id "$SUBNET_1"
    --security-group-ids "$EC2_SG_ID"
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}"
    --user-data "$USER_DATA"
    --associate-public-ip-address
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${APP_NAME}-ecs-ec2},{Key=Project,Value=${APP_NAME}}]"
    --count 1
    --region "$AWS_REGION"
    --query 'Instances[0].InstanceId'
    --output text
  )
  if [ -n "$KEY_NAME" ]; then
    RUN_ARGS+=(--key-name "$KEY_NAME")
  fi
  INSTANCE_ID=$(aws ec2 run-instances "${RUN_ARGS[@]}")
  echo "==> Launched EC2 instance ${INSTANCE_ID}"
else
  INSTANCE_ID="$EXISTING_INSTANCE"
  echo "==> Reusing existing EC2 instance ${INSTANCE_ID}"
fi

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION")
echo "==> EC2 ${INSTANCE_ID} running at ${PUBLIC_IP}"

echo "==> Waiting for ECS container instance registration..."
for i in $(seq 1 36); do
  COUNT=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'clusters[0].registeredContainerInstancesCount' --output text)
  if [ "${COUNT:-0}" -ge 1 ]; then
    echo "==> Container instances registered: ${COUNT}"
    break
  fi
  sleep 10
  if [ "$i" -eq 36 ]; then
    echo "ERROR: EC2 did not register with ECS cluster ${CLUSTER_NAME}"
    echo "Check instance logs / IAM role / user-data."
    exit 1
  fi
done

aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'containerInstanceArns' --output table

# ---------------------------------------------------------------------------
# Register EC2-compatible task definition
# ---------------------------------------------------------------------------
EXEC_ROLE_ARN=$(aws iam get-role --role-name ecsTaskExecutionRole --query Role.Arn --output text)
TASK_ROLE_NAME="${TASK_ROLE_NAME:-${APP_NAME}TaskRole}"
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" --query Role.Arn --output text)
LOG_GROUP="/ecs/${APP_NAME}"

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
  | .requiresCompatibilities = ["EC2"]
  | .networkMode = "awsvpc"
  | .executionRoleArn = $exec
  | .taskRoleArn = $task
  | .containerDefinitions[0].name = $cname
  | .containerDefinitions[0].image = $image
  | .containerDefinitions[0].logConfiguration.options["awslogs-group"] = $loggroup
  | .containerDefinitions[0].logConfiguration.options["awslogs-region"] = $region
  ' \
  "${ROOT_DIR}/ecs/task-definition.json" > "$TMP_TD"

NEW_TD_ARN=$(aws ecs register-task-definition \
  --cli-input-json "file://${TMP_TD}" \
  --region "$AWS_REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "==> Registered task definition ${NEW_TD_ARN}"
rm -f "$TMP_TD"

# ---------------------------------------------------------------------------
# Recreate service with EC2 launch type (launch type cannot be updated in-place)
# ---------------------------------------------------------------------------
ACTIVE=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[?status==`ACTIVE`].serviceName | [0]' --output text --region "$AWS_REGION" 2>/dev/null || true)

if [ -n "$ACTIVE" ] && [ "$ACTIVE" != "None" ]; then
  CURRENT_LT=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].launchType' --output text --region "$AWS_REGION")
  echo "==> Existing service launchType=${CURRENT_LT}"
  if [ "$CURRENT_LT" != "EC2" ]; then
    echo "==> Scaling non-EC2 service to 0 and deleting..."
    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
      --desired-count 0 --region "$AWS_REGION" >/dev/null
    aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
      --force --region "$AWS_REGION" >/dev/null
    # Wait until service is fully INACTIVE (cannot recreate while DRAINING)
    for i in $(seq 1 60); do
      ST=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
        --query 'services[0].status' --output text --region "$AWS_REGION" 2>/dev/null || echo "MISSING")
      echo "==> Old service status: ${ST}"
      if [ "$ST" = "MISSING" ] || [ "$ST" = "INACTIVE" ] || [ "$ST" = "None" ]; then
        break
      fi
      sleep 10
    done
    ACTIVE=""
  fi
fi

if [ -z "$ACTIVE" ] || [ "$ACTIVE" = "None" ]; then
  echo "==> Creating ECS service with launch type EC2..."
  # EC2 + awsvpc: assignPublicIp ENABLED is not used here; ALB reaches task ENI via private IP.
  aws ecs create-service \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 1 \
    --launch-type EC2 \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_1},${SUBNET_2}],securityGroups=[${TASK_SG_ID}],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${CONTAINER_NAME},containerPort=5000" \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=200,minimumHealthyPercent=0" \
    --scheduling-strategy REPLICA \
    --region "$AWS_REGION" >/dev/null
else
  echo "==> Updating existing EC2 service..."
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 1 \
    --force-new-deployment \
    --region "$AWS_REGION" >/dev/null
fi

echo "==> Waiting for service stability..."
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$AWS_REGION"

aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" \
  --query 'services[0].{launchType:launchType,status:status,running:runningCount,desired:desiredCount,taskDef:taskDefinition}' \
  --output table

ALB_DNS=$(aws elbv2 describe-load-balancers --names "${APP_NAME}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$AWS_REGION")

echo
echo "========================================================================"
echo "ECS on EC2 migration complete"
echo "========================================================================"
echo "EC2 Instance ID:   ${INSTANCE_ID}"
echo "EC2 Public IP:     ${PUBLIC_IP}"
echo "Launch type:       EC2"
echo "Task definition:   ${NEW_TD_ARN}"
echo "ALB URL:           http://${ALB_DNS}/api/doc"
echo "Health:            http://${ALB_DNS}/health"
echo
echo "Screenshot tips (Part C):"
echo "  1) ECS Cluster (shows 1 Container instance)"
echo "  2) EC2 Console -> Instances -> ${APP_NAME}-ecs-ec2"
echo "  3) Task Definition (requiresCompatibilities = EC2)"
echo "  4) ECS Service (Launch type = EC2)"
echo "  5) Running task + browser ALB URL"
echo "========================================================================"

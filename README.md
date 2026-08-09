# final-python — Docker Hub + Amazon ECS (EC2)

Dockerized Flask REST API with GitHub Actions CI/CD. Images are pushed to **Docker Hub** and deployed to **Amazon ECS on EC2** (one EC2 container instance) behind an Application Load Balancer.

Source application adapted from [lidorg-dev/final-python](https://github.com/lidorg-dev/final-python).

| Item | Value |
|------|--------|
| Repository | https://github.com/john-2331/final-python |
| Docker Hub | https://hub.docker.com/r/john2331/final-python |
| Region | `us-east-1` |
| Launch type | ECS on **EC2** |
| Live app | http://final-python-alb-1567240385.us-east-1.elb.amazonaws.com/api/doc |
| Health | http://final-python-alb-1567240385.us-east-1.elb.amazonaws.com/health |
| Local Swagger | http://localhost:5000/api/doc |

---

## Architecture

```
Push to main
    │
    ▼
GitHub Actions
  ├─ Build Docker image
  ├─ Push to Docker Hub
  └─ Update ECS service
         │
         ▼
Docker Hub ──────────► ECS tasks on EC2 instance
                              ▲
Users ──► ALB (:80) ──────────┘
                              │
                       CloudWatch Logs
```

---

## Repository structure

```
.
├── Dockerfile
├── docker-compose.yml
├── .dockerignore
├── .env.example
├── .github/workflows/deploy.yml
├── app/
├── ecs/
│   ├── task-definition.json
│   └── github-oidc-deploy-policy.json
├── scripts/
│   ├── aws-setup.sh
│   ├── migrate-to-ecs-ec2.sh
│   └── verify.sh
├── docs/
│   ├── README.md
│   ├── PROJECT_DOCUMENTATION.docx
│   └── screenshots/
└── README.md
```

---

## Prerequisites

- Docker Desktop (or Docker Engine) and Docker Compose v2
- GitHub repository with Actions enabled
- Docker Hub account
- AWS account and AWS CLI v2
- `jq`

---

## Local development

### Clone

```bash
git clone https://github.com/john-2331/final-python.git
cd final-python
```

### Build and run with Docker

```bash
docker build -t final-python:local .
docker run --rm -p 5000:5000 --name final-python final-python:local
```

Open:

- http://localhost:5000/health
- http://localhost:5000/api/doc

### Build and run with Docker Compose

```bash
cp .env.example .env
docker compose up --build -d
docker compose ps
docker compose logs -f
docker compose down
```

---

## CI/CD

Workflow file: [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)

**Trigger:** push to `main` (or manual `workflow_dispatch`).

Pipeline steps:

1. Checkout code  
2. Log in to Docker Hub  
3. Build the image  
4. Push `latest` and `<git-sha>` tags to Docker Hub  
5. Register a new ECS task definition revision  
6. Update the ECS service and wait for stability  

### GitHub Secrets

Configure under **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `DOCKERHUB_REPOSITORY` | Image repository name (`final-python`) |
| `AWS_REGION` | AWS region (`us-east-1`) |
| `AWS_ACCESS_KEY_ID` | IAM access key for deploy |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key for deploy |
| `AWS_ROLE_ARN` | Optional OIDC role ARN |
| `ECS_CLUSTER` | `final-python-cluster` |
| `ECS_SERVICE` | `final-python-service` |
| `ECS_TASK_DEFINITION` | `final-python` |
| `CONTAINER_NAME` | `final-python` |

Do not commit secrets to the repository.

---

## AWS deployment

### Services used

| Service | Purpose |
|---------|---------|
| Amazon ECS (EC2 launch type) | Runs the container on one EC2 instance |
| Amazon EC2 | ECS-optimized instance registered to the cluster |
| Application Load Balancer | Public HTTP entrypoint |
| IAM | Task execution role, task role, EC2 instance role |
| CloudWatch Logs | Container logs (`/ecs/final-python`) |
| Security Groups | ALB on port 80; tasks on port 5000 from ALB |

This project does **not** use Amazon ECR. Images are pulled from Docker Hub.

### One-time setup

```bash
export AWS_PROFILE=john
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=139830186794
export DOCKERHUB_USERNAME=john2331
export DOCKERHUB_REPOSITORY=final-python
export GITHUB_ORG=john-2331
export GITHUB_REPO=final-python

./scripts/aws-setup.sh
./scripts/migrate-to-ecs-ec2.sh
```

`aws-setup.sh` creates networking, IAM, ALB, log group, and cluster resources.  
`migrate-to-ecs-ec2.sh` launches the EC2 instance and creates/updates the ECS service with launch type **EC2**.

### Task definition

[`ecs/task-definition.json`](ecs/task-definition.json):

- `requiresCompatibilities`: `["EC2"]`
- Network mode: `awsvpc`
- CPU `256` / memory `512`
- Container port `5000`
- Image: `john2331/final-python:<tag>`
- Logs: CloudWatch group `/ecs/final-python`

### Deployed resources

| Resource | Name / value |
|----------|----------------|
| Cluster | `final-python-cluster` |
| Container instances | 1 |
| EC2 instance | `final-python-ecs-ec2` |
| Service | `final-python-service` |
| Launch type | `EC2` |
| Task family | `final-python` |
| ALB DNS | `final-python-alb-1567240385.us-east-1.elb.amazonaws.com` |

### Manual deploy commands

```bash
aws ecs register-task-definition \
  --cli-input-json file://ecs/task-definition.json \
  --region us-east-1

aws ecs update-service \
  --cluster final-python-cluster \
  --service final-python-service \
  --task-definition final-python \
  --force-new-deployment \
  --region us-east-1

aws ecs wait services-stable \
  --cluster final-python-cluster \
  --services final-python-service \
  --region us-east-1
```

---

## Verification

```bash
# Local
./scripts/verify.sh local

# Docker Hub (requires DOCKERHUB_* env vars)
./scripts/verify.sh hub

# ECS (requires AWS credentials + ECS_* env vars)
export AWS_REGION=us-east-1
export ECS_CLUSTER=final-python-cluster
export ECS_SERVICE=final-python-service
export ALB_DNS=final-python-alb-1567240385.us-east-1.elb.amazonaws.com
./scripts/verify.sh ecs
```

Useful AWS checks:

```bash
aws ecs describe-services \
  --cluster final-python-cluster \
  --services final-python-service \
  --query 'services[0].{launchType:launchType,running:runningCount,desired:desiredCount}'

aws ecs describe-clusters \
  --clusters final-python-cluster \
  --query 'clusters[0].registeredContainerInstancesCount'

curl http://final-python-alb-1567240385.us-east-1.elb.amazonaws.com/health
```

---

## Screenshots

Evidence images are stored in [`docs/screenshots/`](docs/screenshots/):

| File | Description |
|------|-------------|
| `01-github-repo.png` | GitHub repository |
| `02-dockerfile.png` | Dockerfile |
| `03-local-app.png` | Application running locally in the browser |
| `04-workflow-yaml.png` | GitHub Actions workflow file |
| `05-workflow-success.png` | Successful workflow run |
| `06-dockerhub.png` | Docker Hub repository with image tags |
| `07-ecs-cluster.png` | ECS cluster |
| `08-task-definition.png` | ECS task definition (EC2) |
| `09-ecs-service.png` | ECS service (launch type EC2) |
| `10-live-app.png` | Live application via ALB |

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `5000` | Application port |
| `FLASK_DEBUG` | `0` | Flask debug flag |
| `DATABASE_URI` | `sqlite:///data.db` | SQLAlchemy database URI |
| `APP_PORT` | `5000` | Host port for Compose |

---

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| Docker Hub login fails in Actions | Verify `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` |
| Image pull errors on ECS | Confirm the Hub repository is public, or configure Hub credentials for ECS |
| No container instance in cluster | Ensure EC2 instance `final-python-ecs-ec2` is running and registered |
| ALB returns 502 | Check task health, security groups, and CloudWatch logs |
| Deploy stuck waiting for stability | `aws logs tail /ecs/final-python --follow` |

---

## Attribution

Application code adapted from [lidorg-dev/final-python](https://github.com/lidorg-dev/final-python).

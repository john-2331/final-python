# Documentation

Project documentation for **final-python** — Docker Hub CI/CD and Amazon ECS on EC2.

## Documents in this folder

| File | Description |
|------|-------------|
| [`README.md`](README.md) | This documentation index |
| [`PROJECT_DOCUMENTATION.docx`](PROJECT_DOCUMENTATION.docx) | Full course submission document (Parts A, B, C) with explanations and embedded screenshots |
| [`screenshots/`](screenshots/) | Numbered evidence screenshots (`01`–`10`) |

## Quick links

| Item | URL / value |
|------|-------------|
| GitHub | https://github.com/john-2331/final-python |
| Docker Hub | https://hub.docker.com/r/john2331/final-python |
| Live app | http://final-python-alb-1567240385.us-east-1.elb.amazonaws.com/api/doc |
| Health | http://final-python-alb-1567240385.us-east-1.elb.amazonaws.com/health |
| Local app | http://localhost:5000/api/doc |

## Deployment summary

- **Registry:** Docker Hub (`john2331/final-python`) — not Amazon ECR  
- **CI/CD:** GitHub Actions (`.github/workflows/deploy.yml`)  
- **Compute:** Amazon ECS with **EC2** launch type (one EC2 instance)  
- **Cluster:** `final-python-cluster`  
- **Service:** `final-python-service`  
- **Task definition:** `final-python` (`requiresCompatibilities: ["EC2"]`)  
- **EC2 instance:** `final-python-ecs-ec2`  
- **Region:** `us-east-1`  

Setup scripts (from repo root):

```bash
./scripts/aws-setup.sh
./scripts/migrate-to-ecs-ec2.sh
```

## Screenshots

| File | Description |
|------|-------------|
| `01-github-repo.png` | GitHub repository |
| `02-dockerfile.png` | Dockerfile |
| `03-local-app.png` | Local application in browser |
| `04-workflow-yaml.png` | GitHub Actions workflow YAML |
| `05-workflow-success.png` | Successful workflow run |
| `06-dockerhub.png` | Docker Hub repository |
| `07-ecs-cluster.png` | ECS cluster |
| `08-task-definition.png` | ECS task definition (EC2) |
| `09-ecs-service.png` | ECS service (launch type EC2) |
| `10-live-app.png` | Live application via ALB |

See [`screenshots/README.md`](screenshots/README.md) for details.

## Main project README

For clone/build/deploy instructions, see the root [`README.md`](../README.md).

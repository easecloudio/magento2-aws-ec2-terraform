# Magento 2 AWS EC2 Auto Scaling Cluster — Terraform

Deploy a production-ready, auto-scaling Magento 2 infrastructure on AWS using Terraform and EC2 Graviton instances.

## Overview

This project provisions a complete Magento 2 infrastructure on AWS including:

- **EC2 Auto Scaling Groups** — frontend (PHP-FPM + Nginx) and varnish tiers on ARM Graviton
- **RDS MariaDB** — managed relational database with Parameter Store credential management
- **ElastiCache Redis** — session and full-page cache clusters
- **OpenSearch** — Magento catalog search
- **Amazon MQ (RabbitMQ)** — async message queue
- **Application Load Balancer** — with WAF, SSL termination, and geo-blocking
- **CloudFront CDN** — with Lambda@Edge URL normalization and Lambda image optimization via imgproxy
- **EFS** — shared `var/` and `media/` mount across all EC2 instances
- **S3** — media, optimized media, system files, and backups
- **SSM Automation** — instance initialization, configuration, and release deployment without SSH
- **AWS Cloud Map** — automatic service discovery registration on instance launch
- **CodeDeploy** — application release pipeline from S3

All configuration is driven by a single YAML file per environment (`developer.config.yaml`, `staging.config.yaml`, `production.config.yaml`). No `.tfvars` files needed.

## Prerequisites

- Terraform >= 1.9
- AWS CLI configured with sufficient IAM permissions
- An AWS account with access to all services above
- [Subscribe to Debian 12 ARM AMI](https://aws.amazon.com/marketplace/pp/prodview-63gms6fbfaota) in your target region

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/easecloud/magento2-aws-ec2-terraform.git
cd magento2-aws-ec2-terraform

# 2. Edit your environment config
cp developer.config.yaml production.config.yaml
# Edit production.config.yaml: set brand, domain, admin_email, instance types, etc.

# 3. Initialize Terraform
terraform init

# 4. Create a workspace matching your config file name
terraform workspace new production

# 5. Plan and apply
terraform plan -out production.plan
terraform apply production.plan
```

> After `terraform apply` you will receive an email from AWS SNS to confirm the subscription.

## Configuration

All environment settings live in `<workspace>.config.yaml`. Copy `developer.config.yaml` as a starting point:

| Key | Description |
|-----|-------------|
| `brand` | Short brand identifier — used in all resource names |
| `codename` | Project codename — combined with brand as `brand-codename` |
| `domain` | Primary domain name for Route 53 and ACM |
| `admin_email` | Email for SNS alerts and SES |
| `ec2.frontend` | Instance type, volume size, ASG capacity settings |
| `ec2.varnish` | Instance type, volume size, ASG capacity settings |
| `rds` | MariaDB engine version, instance class, storage |
| `redis` | ElastiCache node type, cluster count |
| `opensearch` | Engine version, instance type |
| `rabbitmq` | Engine version, instance type |
| `waf.restricted_countries` | ISO country codes to block at WAF |

For the full reference see `developer.config.yaml`.

## Workspaces

Terraform workspaces map directly to config files:

| Workspace | Config file |
|-----------|-------------|
| `developer` | `developer.config.yaml` |
| `staging` | `staging.config.yaml` |
| `production` | `production.config.yaml` |

Switch workspaces with `terraform workspace select <name>`.

## Architecture

```
Internet
   │
   ▼
CloudFront (CDN + WAF + Lambda@Edge)
   │
   ▼
Application Load Balancer
   │
   ├──▶ Varnish ASG (cache layer)
   │         │
   └──▶ Frontend ASG (Nginx + PHP-FPM)
              │
              ├──▶ RDS MariaDB
              ├──▶ ElastiCache Redis (session + cache)
              ├──▶ OpenSearch
              ├──▶ Amazon MQ (RabbitMQ)
              ├──▶ EFS (var/ + media/)
              └──▶ S3 (media + system)
```

## Instance Initialization

When an EC2 instance launches, the SSM Automation document `<project>-InstanceInitialization` runs automatically via an ASG association. It:

1. Waits for instance status OK
2. Writes helper scripts (`/usr/local/bin/parameterstore`, `metadata`, `leader`)
3. Installs base packages: AWS CLI v2, CloudWatch Agent, Ansible
4. Runs the Ansible playbook for the instance type from S3
5. Registers the instance in AWS Cloud Map for service discovery

## Security

- Credentials stored as `SecureString` in SSM Parameter Store
- No SSH access — all management via AWS Systems Manager Session Manager
- WAF rules: geo-blocking, IP allowlist/blocklist, rate limiting
- Security groups scoped per service tier
- IMDSv2 enforced on all instances

## License

Apache 2.0 — see [LICENSE](LICENSE)

# Prerequisites

This document covers everything you need before running `terraform init`.

---

## AWS Account and IAM

You need an AWS account with permissions to create every service in the stack: VPC, EC2, RDS, ElastiCache, OpenSearch, Amazon MQ, ALB, CloudFront, WAF, EFS, S3, SSM, CodeDeploy, Cloud Map, EventBridge, SES, Route 53, ACM, SNS, SQS, CloudWatch, and Budgets.

For an initial deployment, attach the `AdministratorAccess` managed policy to the IAM user or role you are deploying with. For ongoing operations, scope this down to the services above after the first apply.

Configure the AWS CLI:

```bash
aws configure
# AWS Access Key ID: ...
# AWS Secret Access Key: ...
# Default region name: us-east-1   # or your target region
# Default output format: json
```

Verify access:

```bash
aws sts get-caller-identity
```

---

## Required Tools

| Tool | Minimum version | Install |
|------|----------------|---------|
| Terraform | 1.9 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |

---

## Terraform State Backend

Terraform state must be stored remotely in S3 with DynamoDB for state locking. Create the bucket and table before running `terraform init`:

```bash
# Create the state bucket (choose a unique name)
aws s3 mb s3://your-org-tfstate --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket your-org-tfstate \
  --versioning-configuration Status=Enabled

# Create the DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Create a `state.config` file at the root of the repo (do not commit this file):

```hcl
bucket         = "your-org-tfstate"
key            = "magento2-ec2/developer.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-state-lock"
```

Pass it to every `terraform init` call:

```bash
terraform init -backend-config=state.config
```

---

## Debian 12 ARM AMI Marketplace Subscription

The launch templates use the latest `debian-12-arm64` AMI published by Debian (owner `136693071363`). This AMI requires a one-time subscription in the AWS Marketplace before EC2 can launch instances from it.

Subscribe before running `terraform apply`:

1. Open https://aws.amazon.com/marketplace/pp/prodview-63gms6fbfaota in the AWS Console.
2. Click **Continue to Subscribe**.
3. Accept the terms.
4. You do not need to launch an instance from the Marketplace page — Terraform will reference the AMI directly.

Failure to subscribe results in an `OptInRequired` error on the ASG launch template.

---

## Domain Name and Route 53

Terraform creates a Route 53 public hosted zone for `domain` specified in your config YAML. It does not transfer or register the domain.

After the first `terraform apply`:

1. Run `terraform output` or check the AWS Console for the Route 53 NS records.
2. Log into your domain registrar and set the four Route 53 nameservers as the authoritative NS for your domain.
3. ACM certificate validation is performed automatically via Route 53 DNS records. The certificate will become valid once DNS delegation is complete and propagates (typically 5–15 minutes).

---

## ACM Certificates

Two certificates are created:

- One in the deployment region for the ALB.
- One in `us-east-1` for CloudFront (CloudFront requires certificates in us-east-1).

Both are validated automatically via Route 53. No manual action is needed beyond delegating the nameservers.

---

## SES Sandbox

SES is used for Magento transactional email. New AWS accounts are placed in the SES sandbox, which restricts sending to verified addresses only.

Before go-live, request production SES access:

1. In the AWS Console, go to **SES → Account dashboard → Request production access**.
2. Describe your sending use case (transactional email for an e-commerce store).
3. Approval typically takes 24 hours.

The SES SMTP credentials (key, secret, and SMTP password) are written to SSM Parameter Store by Terraform and are available to Magento via the Ansible configuration playbook.

---

## Ansible Setup Packages in S3

Instance configuration is handled by Ansible playbooks that run inside the SSM Automation `InstanceInitialization` document. Terraform creates the S3 `system` bucket, but it does not upload the Ansible playbooks — you must do this before instances can complete initialization.

The SSM document syncs from:

```
s3://<project>-system/setup/<instance_name>/
```

and expects a zip archive named `<instance_name>.zip` inside that prefix, which must unzip to an Ansible playbook named `<instance_name>.yml`.

Required uploads before instances will initialize:

```
s3://<brand>-<codename>-system/setup/frontend/frontend.zip
s3://<brand>-<codename>-system/setup/varnish/varnish.zip
```

Upload example:

```bash
aws s3 cp frontend.zip s3://easecloud-magento-system/setup/frontend/frontend.zip
aws s3 cp varnish.zip  s3://easecloud-magento-system/setup/varnish/varnish.zip
```

Each zip must contain:
- `<instance_name>.yml` — the top-level Ansible playbook
- Any roles, templates, or files the playbook references

The SSM document passes the following extra variables to `ansible-playbook`:
- `SSM=True`
- `instance_name` — `frontend` or `varnish`
- `instance_ip` — the instance's private IPv4 address

All service endpoints, credentials, and configuration values are available via SSM Parameter Store under the path `/<project>/<key>` and can be retrieved from within the playbook using the `/usr/local/bin/parameterstore` helper script written during init.

---

## AWS Service Quotas

Check and request increases for the following quotas before deploying into a fresh account or a region where you have not previously used these services:

| Service | Quota to check |
|---------|---------------|
| EC2 | Running On-Demand `C` (Compute Optimized) instances — the `c7g` family falls under this vCPU quota. Default is often 32 vCPUs; a 4-instance `c7g.xlarge` deployment uses 16 vCPUs. |
| EFS | File systems per account per region (default 1000, rarely an issue). |
| RDS | DB instances per account per region (default 40). |
| ElastiCache | Clusters per region (default 300). |
| OpenSearch | Domains per region (default 100). |
| VPC | VPCs per region (default 5) — ensure you have room for a new VPC. |

Request increases at **AWS Console → Service Quotas** before applying if any limits are close.

# EC2 Quick Start

This guide walks through a complete deployment from zero to a running Magento 2 infrastructure. Complete all steps in the [Prerequisites](prerequisites.md) document before starting.

---

## Step 1 — Subscribe to the Debian 12 ARM AMI

1. Open https://aws.amazon.com/marketplace/pp/prodview-63gms6fbfaota
2. Click **Continue to Subscribe** and accept the terms.
3. No instance needs to be launched from the Marketplace page.

This is a one-time action per AWS account. Without it, the ASG launch templates will fail with `OptInRequired`.

---

## Step 2 — Clone the Repository

```bash
git clone https://github.com/easecloud/magento2-aws-ec2-terraform.git
cd magento2-aws-ec2-terraform
```

---

## Step 3 — Edit `developer.config.yaml`

At minimum set the three identity fields before any apply:

```yaml
brand: yourcompany       # short identifier, lowercase; used in all resource names
codename: magento        # project codename; combined with brand as "yourcompany-magento"
domain: "yourdomain.com" # the primary domain for Route 53, ACM, and CloudFront
admin_email: "admin@yourdomain.com"
```

Review the remaining settings — instance types, ASG sizing, RDS class, Redis node type — and adjust for your expected load. The defaults are suitable for a moderate-traffic store. See [Config Reference](config-reference.md) for a full field description.

Do not change `brand`, `codename`, or `vpc.cidr_block` after the first apply. These values are embedded in resource names and VPC addressing; changing them requires destroying and recreating the entire stack.

---

## Step 4 — Create the S3 State Backend Bucket

```bash
aws s3 mb s3://your-org-tfstate --region us-east-1

aws s3api put-bucket-versioning \
  --bucket your-org-tfstate \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

---

## Step 5 — Create `state.config`

Create a file named `state.config` at the repo root. Do not commit it.

```hcl
bucket         = "your-org-tfstate"
key            = "magento2-ec2/developer.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-state-lock"
```

---

## Step 6 — Initialize Terraform

```bash
terraform init -backend-config=state.config
```

Terraform downloads the required providers (`hashicorp/aws` 5.88.0, `hashicorp/random`, `hashicorp/archive`, `hashicorp/null`) and configures the S3 backend.

---

## Step 7 — Create the Workspace

Terraform workspaces map directly to config files. The workspace name must match the config YAML filename prefix:

```bash
terraform workspace new developer
```

Verify:

```bash
terraform workspace show
# developer
```

---

## Step 8 — Plan

```bash
terraform plan -out developer.plan
```

Review the output. Expect roughly 150–180 resources to be created on a fresh deployment. Pay attention to any warnings about region-specific service availability.

---

## Step 9 — Apply

```bash
terraform apply developer.plan
```

The apply takes approximately 20–40 minutes. The slowest resources are OpenSearch domain creation (~15 min), RDS instance creation (~10 min), and ACM certificate validation (depends on DNS propagation).

---

## Step 10 — Confirm the SNS Subscription

After `terraform apply` completes, AWS SNS sends a confirmation email to `admin_email`. Open the email and click **Confirm subscription**. Without this step, you will not receive ASG lifecycle notifications, CloudWatch alarms, or CodeDeploy deployment notifications.

---

## Step 11 — Delegate Route 53 Nameservers

1. In the AWS Console, go to **Route 53 → Hosted zones → your domain**.
2. Find the NS record — it contains four nameserver hostnames.
3. Log into your domain registrar and replace the existing nameservers with these four values.
4. ACM certificate validation completes automatically once DNS propagates (typically 5–15 minutes for major registrars).

You can check certificate status:

```bash
aws acm list-certificates --region us-east-1
aws acm describe-certificate --certificate-arn <arn> --region us-east-1 \
  --query 'Certificate.Status'
```

---

## Step 12 — Upload Ansible Setup Packages to S3

Instances cannot complete initialization until the Ansible playbooks are available in S3. Upload a zip archive for each instance type to the `system` bucket created by Terraform:

```bash
# The system bucket name follows the pattern: <brand>-<codename>-system
# Example: easecloud-magento-system

aws s3 cp frontend.zip s3://easecloud-magento-system/setup/frontend/frontend.zip
aws s3 cp varnish.zip  s3://easecloud-magento-system/setup/varnish/varnish.zip
```

Each zip must contain:
- `<instance_name>.yml` — top-level Ansible playbook (e.g. `frontend.yml`)
- Any roles, templates, files, or `requirements.yml` the playbook references

The playbook runs with the following Ansible extra vars:
- `SSM=True`
- `instance_name` — `frontend` or `varnish`
- `instance_ip` — the instance's private IPv4

All infrastructure connection strings and secrets are available in SSM Parameter Store under `/<brand>-<codename>/<KEY>`. Use the `/usr/local/bin/parameterstore` helper to retrieve them from within the playbook.

---

## Step 13 — Instance Initialization via SSM Automation

When the ASGs launch instances (they start automatically after apply because `desired_capacity` is set in the config), the SSM Association fires the `<project>-InstanceInitialization` automation document on each new instance.

The initialization sequence:

1. Waits for EC2 instance status to be `running` and `ok`.
2. Writes helper scripts: `/usr/local/bin/parameterstore`, `/usr/local/bin/metadata`, `/usr/local/bin/leader`.
3. Installs base packages: AWS CLI v2 (`2.22.0`), Amazon CloudWatch Agent (`1.300049.0b1`), Ansible Core (`2.18.1`), CodeDeploy agent (frontend instances only).
4. Starts the CloudWatch Agent with the SSM-managed config for the instance type.
5. Syncs and runs the Ansible playbook from S3 (`setup/<instance_name>/<instance_name>.zip`).
6. Retrieves the CloudMap service ID from the instance's `CloudmapId` tag.
7. Registers the instance's private IP in AWS Cloud Map.
8. Publishes a completion notification to SNS.

Monitor progress in **AWS Console → Systems Manager → Automation → Executions**, or in CloudWatch Logs under the log group `<project>-InstanceConfiguration`.

If initialization fails because the setup zip was not yet in S3, re-upload the zip. The S3 upload event triggers EventBridge, which automatically re-runs `<project>-InstanceConfiguration` on all running instances of that type.

---

## Step 14 — Deploy the First Application Release

Once instances are initialized and registered in Cloud Map, deploy the Magento application:

1. Package your Magento release as a zip containing `appspec.yml` and deployment scripts.
2. Upload it to the `system` S3 bucket under the `release/` prefix:

```bash
aws s3 cp release-v1.0.0.zip s3://easecloud-magento-system/release/release-v1.0.0.zip
```

The S3 upload event triggers EventBridge, which automatically starts the `<project>-LatestReleaseDeployment` SSM Automation document, which calls CodeDeploy.

You can also trigger a deployment manually:

```bash
aws ssm start-automation-execution \
  --document-name "easecloud-magento-LatestReleaseDeployment" \
  --parameters "S3ObjectKey=release/release-v1.0.0.zip"
```

Monitor the deployment in **AWS Console → CodeDeploy → Applications → easecloud-magento-frontend-codedeploy-app → Deployment groups**.

---

## Step 15 — Verify the Deployment

Check ASG instance health:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names easecloud-magento-frontend-asg easecloud-magento-varnish-asg \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Desired:DesiredCapacity,InService:Instances[?LifecycleState==`InService`]|length(@)}'
```

Check the ALB health check endpoint. The health check path is a randomly generated string stored in SSM Parameter Store under `/<project>/HEALTH_CHECK_LOCATION`. Retrieve it:

```bash
aws ssm get-parameter \
  --name "/easecloud-magento/HEALTH_CHECK_LOCATION" \
  --query Parameter.Value --output text
```

Then verify the varnish target group:

```bash
aws elbv2 describe-target-health \
  --target-group-arn <varnish-target-group-arn>
```

Once varnish instances are `healthy`, CloudFront routes traffic to the ALB. Open your domain in a browser to confirm the storefront is reachable.

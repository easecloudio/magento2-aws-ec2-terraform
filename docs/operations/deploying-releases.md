# Deploying Releases

This document covers application deployment, configuration updates, and the operational commands used to manage the running infrastructure.

---

## Overview

Application releases are deployed via AWS CodeDeploy, triggered by the `<project>-LatestReleaseDeployment` SSM Automation document. The deployment targets the `frontend` Auto Scaling Group only. The `varnish` ASG does not receive application deployments — Varnish configuration changes are handled through instance reconfiguration (see [Instance Configuration](#instance-configuration)).

The deployment path:

```
Release zip -> S3 system bucket (release/ prefix)
    -> EventBridge s3-release-update rule
        -> SSM Automation: <project>-LatestReleaseDeployment
            -> CodeDeploy: CreateDeployment
                -> CodeDeploy agent on each frontend EC2 instance
```

---

## Packaging a Release

A CodeDeploy deployment bundle is a zip file containing an `appspec.yml` and the deployment lifecycle scripts it references.

Minimal `appspec.yml` structure:

```yaml
version: 0.0
os: linux
files:
  - source: /
    destination: /home/<brand>/public_html
hooks:
  BeforeInstall:
    - location: scripts/before_install.sh
      timeout: 300
      runas: root
  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 600
      runas: <brand>
  ApplicationStart:
    - location: scripts/start.sh
      timeout: 300
      runas: root
  ValidateService:
    - location: scripts/validate.sh
      timeout: 60
      runas: <brand>
```

Replace `<brand>` with the value of `brand` in your config YAML (e.g. `easecloud`). The web root path is stored in SSM Parameter Store under `/<project>/WEB_ROOT_PATH`.

Package the release:

```bash
zip -r release-v1.2.3.zip . \
  --exclude ".git/*" \
  --exclude "*.log" \
  --exclude "var/*" \
  --exclude "pub/media/*"
```

---

## Uploading the Release to S3

The system bucket name follows the pattern `<brand>-<codename>-system`. Upload the release zip under the `release/` prefix:

```bash
aws s3 cp release-v1.2.3.zip \
  s3://easecloud-magento-system/release/release-v1.2.3.zip
```

The S3 Object Created event on the `release/` prefix automatically triggers EventBridge, which starts the SSM Automation document and CodeDeploy deployment. No manual trigger is needed when uploading to this prefix.

---

## Triggering a Deployment Manually

To deploy a previously uploaded revision without re-uploading, or to redeploy after a failed automated trigger:

```bash
aws ssm start-automation-execution \
  --document-name "easecloud-magento-LatestReleaseDeployment" \
  --parameters "S3ObjectKey=release/release-v1.2.3.zip"
```

Replace `easecloud-magento` with your project name (`<brand>-<codename>`) and the S3ObjectKey with the full S3 key path of the revision.

The SSM document calls `codedeploy:CreateDeployment` and publishes the deployment ID and start time to the project SNS topic:

```
Subject: Latest release deployment for easecloud-magento
Message: Latest release release/release-v1.2.3.zip deployment d-XXXXXXXXX started 2025-04-16T12:00:00Z
```

---

## How CodeDeploy Deploys

The deployment group is configured as follows:

- **Application**: `<project>-frontend-codedeploy-app`
- **Deployment group**: `<project>-frontend-deployment-group`
- **Target**: `frontend` Auto Scaling Group (all `InService` instances)
- **Deployment config**: `CodeDeployDefault.AllAtOnce` — deploys to all instances simultaneously

The CodeDeploy agent on each frontend instance (installed during SSM initialization) receives the deployment, downloads the revision zip from S3, and executes the `appspec.yml` lifecycle hooks in order:
`ApplicationStop` → `BeforeInstall` → `Install` → `AfterInstall` → `ApplicationStart` → `ValidateService`.

---

## Monitoring Deployments

**AWS Console:**

1. Go to **CodeDeploy → Applications → `<project>-frontend-codedeploy-app`**.
2. Click **Deployment groups → `<project>-frontend-deployment-group`**.
3. View the latest deployment and per-instance status.

**CLI — list recent deployments:**

```bash
aws deploy list-deployments \
  --application-name easecloud-magento-frontend-codedeploy-app \
  --deployment-group-name easecloud-magento-frontend-deployment-group \
  --query 'deployments' --output text
```

**CLI — get deployment status:**

```bash
aws deploy get-deployment \
  --deployment-id d-XXXXXXXXX \
  --query 'deploymentInfo.{Status:status,Created:createTime,ErrorCode:errorInformation.code}'
```

**CLI — get per-instance status:**

```bash
aws deploy list-deployment-instances \
  --deployment-id d-XXXXXXXXX \
  --query 'instancesList' --output text | \
xargs -I {} aws deploy get-deployment-instance \
  --deployment-id d-XXXXXXXXX \
  --instance-id {}
```

**CloudWatch Logs:**

CodeDeploy agent logs are written to `/var/log/aws/codedeploy-agent/codedeploy-agent.log` on each instance. If CloudWatch agent is configured to ship system logs, they appear in the log group for the instance type.

---

## Rollback

### Automatic Rollback

The deployment group can be configured for automatic rollback on failure by adding a `auto_rollback_configuration` block to the `aws_codedeploy_deployment_group` resource in `codedeploy.tf`. By default this is not enabled; failed deployments leave instances in a failed state and require manual intervention.

### Manual Rollback via Console

1. Go to **CodeDeploy → Deployment groups → `<project>-frontend-deployment-group`**.
2. Locate the last successful deployment.
3. Click **Redeploy**.

### Manual Rollback via CLI

```bash
# Get the deployment ID of the last successful deployment
LAST_GOOD=$(aws deploy list-deployments \
  --application-name easecloud-magento-frontend-codedeploy-app \
  --deployment-group-name easecloud-magento-frontend-deployment-group \
  --include-only-statuses Succeeded \
  --query 'deployments[0]' --output text)

# Get the S3 revision from that deployment
aws deploy get-deployment \
  --deployment-id $LAST_GOOD \
  --query 'deploymentInfo.revision.s3Location'

# Trigger a new deployment using that revision key
aws ssm start-automation-execution \
  --document-name "easecloud-magento-LatestReleaseDeployment" \
  --parameters "S3ObjectKey=release/release-v1.2.2.zip"
```

---

## Instance Configuration

Instance configuration (the Ansible playbook that installs and configures Nginx, PHP-FPM, Varnish, etc.) is separate from application releases. It is managed by the `<project>-InstanceConfiguration` SSM Automation document.

### Triggering Configuration

**Via S3 upload (automatic):**

Upload an updated setup zip to the `setup/<instance_name>/` prefix in the system bucket. EventBridge automatically triggers `<project>-InstanceConfiguration` for all running instances of that type:

```bash
aws s3 cp frontend.zip \
  s3://easecloud-magento-system/setup/frontend/frontend.zip
```

**Via SSM Automation (manual):**

```bash
aws ssm start-automation-execution \
  --document-name "easecloud-magento-InstanceConfiguration" \
  --parameters "S3ObjectKey=setup/frontend/frontend.zip"
```

The document:
1. Extracts the instance name from the S3 key path.
2. Finds all EC2 instances with a matching `InstanceName` tag that are currently running.
3. Runs the Ansible playbook on all matching instances concurrently via `aws:runCommand`.
4. Publishes a completion notification to SNS.

### Configuration Flow

The Ansible playbook is downloaded from S3 on every configuration run — there is no cached local copy used. This ensures the latest version is always applied. The sync command uses `--exact-timestamps --delete` so removed files are cleaned up.

---

## Cloud Map Registration

Instances register themselves in AWS Cloud Map during initialization and are deregistered on termination:

- **Registration**: performed by the `RegisterInstanceInCloudMap` step in `<project>-InstanceInitialization`. Registers the instance's private IPv4 under the service `<project>-<instance_type>-<az>` in the `<brand>.internal` private DNS namespace.
- **Deregistration**: performed by the `<project>-CloudMapDeregister` SSM Automation document, triggered by EventBridge on the `autoscaling:EC2_INSTANCE_TERMINATING` lifecycle event.

Cloud Map provides private DNS A records (TTL 10 seconds) that Varnish uses to discover backend frontend instances. If an instance fails to register (e.g. because the Ansible playbook failed), it will not receive traffic from Varnish regardless of its ALB health check status.

To check registrations for a service:

```bash
aws servicediscovery list-instances \
  --service-id <service-id>
```

Retrieve the service ID from SSM Parameter Store:

```bash
aws ssm get-parameter \
  --name "/easecloud-magento/FRONTEND_CLOUDMAP_SERVICE_ID" \
  --query Parameter.Value --output text
```

---

## Useful Operational Commands

**List all SSM parameters for the project:**

```bash
aws ssm get-parameters-by-path \
  --path "/easecloud-magento/" \
  --with-decryption \
  --query 'Parameters[].{Name:Name,Value:Value}' \
  --output table
```

**Start an SSM Session Manager session on a frontend instance:**

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names easecloud-magento-frontend-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)

aws ssm start-session --target $INSTANCE_ID
```

**Force an ASG instance refresh (rolling restart with new launch template):**

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name easecloud-magento-frontend-asg \
  --preferences MinHealthyPercentage=50
```

**Manually scale the frontend ASG:**

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name easecloud-magento-frontend-asg \
  --desired-capacity 4
```

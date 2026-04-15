# Configuration Reference

All infrastructure settings are defined in a single YAML file per environment. The filename must match the Terraform workspace name:

| Workspace | Config file |
|-----------|-------------|
| `developer` | `developer.config.yaml` |
| `staging` | `staging.config.yaml` |
| `production` | `production.config.yaml` |

Terraform reads the config with `yamldecode(file("${workspace}.config.yaml"))`. Unknown keys are ignored, but missing required keys cause a Terraform error at plan time.

Keys marked **immutable** cannot be changed after the first `terraform apply` without destroying and recreating the entire stack (or at minimum the resources that depend on them).

---

## Top-Level Identity

| Key | Type | Example | Description |
|-----|------|---------|-------------|
| `brand` | string | `easecloud` | Short brand identifier. Combined with `codename` as `brand-codename` to form the project name used in every resource name, S3 bucket name, IAM role name, SSM parameter path, and CloudMap namespace. Lowercase, no spaces. **Immutable.** |
| `codename` | string | `magento` | Project codename. Combined with `brand` to produce the project identifier. **Immutable.** |
| `github_repo` | string | `your-org/your-magento-repo` | GitHub repository reference. Currently informational — not consumed by Terraform resources in this release. |
| `domain` | string | `yourdomain.com` | Primary domain. Used for Route 53 hosted zone, ACM certificate, CloudFront aliases, ALB listener rule host-header match, and SSM parameters. |
| `admin_email` | string | `admin@yourdomain.com` | Email address for SNS topic subscription. Receives ASG lifecycle events, CloudWatch alarms, CodeDeploy notifications, and SSM execution logs. |

---

## VPC

Affects: `aws_vpc`, `aws_subnet`, `aws_vpc_dhcp_options`, and all resources that depend on VPC or subnet IDs.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vpc.cidr_block` | string | `172.35.0.0/16` | VPC CIDR block. Subnets are carved with a `/4` offset per AZ (`cidrsubnet(cidr, 4, az_index)`). **Immutable** — changing requires VPC and all dependent resources to be replaced. |
| `vpc.availability_zones_qty` | integer | `2` | Number of Availability Zones to deploy into. Subnets, EFS mount targets, and Cloud Map services are created per AZ. Increasing this value after first apply adds new subnets but does not migrate existing resources. |
| `vpc.enable_dns_support` | bool | `true` | Enables DNS resolution in the VPC. Required for Cloud Map private DNS and RDS/ElastiCache endpoint resolution. Do not disable. |
| `vpc.enable_dns_hostnames` | bool | `true` | Enables DNS hostnames for VPC resources. Required for SSM Agent communication. Do not disable. |
| `vpc.instance_tenancy` | string | `default` | EC2 instance tenancy. `default` uses shared hardware. `dedicated` adds significant cost and is only required for strict compliance workloads. |

---

## EC2

Affects: `aws_launch_template`, `aws_autoscaling_group`.

The `ec2` key contains two sub-keys: `frontend` and `varnish`. Each sub-key applies to the corresponding ASG.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ec2.frontend.instance_type` | string | `c7g.xlarge` | EC2 instance type for the frontend ASG (Nginx + PHP-FPM + imgproxy). Must be an ARM Graviton type to match the Debian 12 ARM AMI. Changing this value triggers a launch template update and instance refresh. |
| `ec2.frontend.volume_size` | string | `25` | EBS root volume size in GiB for frontend instances. Type is always `gp3`, encrypted. Adjust upward if the application codebase or local caches are large. |
| `ec2.frontend.desired_capacity` | integer | `2` | Initial desired instance count for the frontend ASG. Can be overridden by Auto Scaling policies at runtime. |
| `ec2.frontend.min_size` | integer | `2` | Minimum number of frontend instances. Scale-in policies will not reduce below this count. |
| `ec2.frontend.max_size` | integer | `8` | Maximum number of frontend instances. Scale-out policies will not exceed this count. A CloudWatch alarm fires when the ASG reaches `max_size`. |
| `ec2.varnish.instance_type` | string | `c7g.large` | EC2 instance type for the varnish ASG. Must be ARM Graviton. |
| `ec2.varnish.volume_size` | string | `25` | EBS root volume size in GiB for varnish instances. |
| `ec2.varnish.desired_capacity` | integer | `2` | Initial desired instance count for the varnish ASG. |
| `ec2.varnish.min_size` | integer | `2` | Minimum number of varnish instances. |
| `ec2.varnish.max_size` | integer | `8` | Maximum number of varnish instances. |

---

## ASG — Auto Scaling Group

Affects: `aws_autoscaling_group` (both frontend and varnish).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `asg.health_check_type` | string | `EC2` | Health check type used by the ASG. `EC2` uses EC2 instance status checks. `ELB` uses ALB target group health checks. Use `ELB` in production so the ASG replaces instances that fail the ALB health check. |
| `asg.health_check_grace_period` | string | `300` | Seconds after instance launch before health checks begin. Allows time for initialization to complete. Increase if SSM initialization takes longer than 5 minutes in your environment. |

---

## ASP — Auto Scaling Policy

Affects: `aws_autoscaling_policy` (scaleout, scalein), `aws_cloudwatch_metric_alarm` (scaleout, scalein). The same policy values are applied to both the `frontend` and `varnish` ASGs.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `asp.out_threshold` | string | `80` | CPU utilization percentage above which scale-out is triggered. The alarm uses `GreaterThanThreshold` comparison, so scaling starts when CPU exceeds this value. |
| `asp.in_threshold` | string | `25` | CPU utilization percentage below which scale-in is triggered. |
| `asp.period` | string | `300` | CloudWatch alarm evaluation period in seconds. Each data point covers this duration. |
| `asp.evaluation_periods_out` | string | `1` | Number of consecutive periods the out_threshold must be exceeded before scaling out. Lower values respond faster but are more sensitive to spikes. |
| `asp.evaluation_periods_in` | string | `2` | Number of consecutive periods the in_threshold must be met before scaling in. Higher values prevent premature scale-in after a traffic burst. |

Cooldown period for both scale-out and scale-in policies is hardcoded to 300 seconds.

---

## OpenSearch

Affects: `aws_opensearch_domain`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `opensearch.engine_version` | string | `OpenSearch_2.17` | OpenSearch engine version string. Must be a valid AWS OpenSearch version identifier. |
| `opensearch.instance_type` | string | `m6g.large.search` | OpenSearch instance type. Use Graviton-based types (`m6g`, `r6g`) for cost efficiency. |
| `opensearch.instance_count` | integer | `1` | Number of data nodes. A single node has no replication. Increase to `2` or `3` with a dedicated master for production HA. |
| `opensearch.ebs_enabled` | bool | `true` | Enables EBS storage. Required for all non-ultrawarm instances. |
| `opensearch.volume_type` | string | `gp3` | EBS volume type for OpenSearch data nodes. |
| `opensearch.volume_size` | string | `50` | EBS volume size in GiB per data node. Magento catalog indices grow with product count; monitor and increase as needed. |
| `opensearch.log_type` | string | `ES_APPLICATION_LOGS` | CloudWatch log type published by the OpenSearch domain. |

---

## RDS

Affects: `aws_db_instance`, `aws_db_parameter_group`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `rds.allocated_storage` | string | `50` | Initial allocated storage in GiB. With autoscaling enabled, RDS can grow up to `max_allocated_storage`. |
| `rds.max_allocated_storage` | string | `100` | Maximum storage autoscaling ceiling in GiB. |
| `rds.storage_type` | string | `gp3` | EBS storage type. `gp3` provides predictable baseline IOPS. |
| `rds.storage_encrypted` | bool | `true` | Enables AES-256 encryption at rest. Cannot be disabled after creation without snapshot restore. |
| `rds.engine` | string | `mariadb` | Database engine. Do not change — the parameter group, family, and many defaults assume MariaDB. |
| `rds.engine_version` | string | `10.11.21` | MariaDB engine version. Minor version patches can be applied in-place. Major version upgrades require a snapshot restore. |
| `rds.family` | string | `mariadb10.11` | Parameter group family. Must match the major version of `engine_version`. |
| `rds.instance_class` | string | `db.m7g.large` | RDS instance class. The `max_connection_count` local in `locals.tf` maps instance classes to connection limits used to set the `max_connections` parameter. Use `db.m7g` or `db.r7g` Graviton classes for cost efficiency. |
| `rds.skip_final_snapshot` | bool | `true` | Skips the final snapshot on RDS deletion. Set to `false` in production. |
| `rds.multi_az` | bool | `false` | Enables Multi-AZ standby. Set to `true` in production for automatic failover. |
| `rds.enabled_cloudwatch_logs_exports` | string | `error` | CloudWatch log type to export. Options: `audit`, `error`, `general`, `slowquery`. |
| `rds.performance_insights_enabled` | bool | `true` | Enables RDS Performance Insights for query-level analysis. |
| `rds.copy_tags_to_snapshot` | bool | `true` | Copies RDS instance tags to automated snapshots. |
| `rds.backup_retention_period` | string | `0` | Days to retain automated backups. `0` disables automated backups. Set to `7` or higher in production. |
| `rds.delete_automated_backups` | bool | `true` | Deletes automated backups on instance deletion. |
| `rds.deletion_protection` | bool | `false` | Prevents accidental deletion via Terraform or the AWS Console. Set to `true` in production. |
| `rds.parameters` | list of `{name, value}` | (see below) | RDS parameter group overrides. Applied to the `mariadb10.11` parameter group. Changes to static parameters require an instance reboot. |

Default RDS parameters and their purpose:

| Parameter | Value | Reason |
|-----------|-------|--------|
| `max_allowed_packet` | `268435456` (256 MB) | Required for large Magento import/export operations |
| `max_connect_errors` | `500` | Prevents hosts from being blocked after transient errors |
| `interactive_timeout` | `7200` | Keeps long-running admin sessions alive |
| `wait_timeout` | `7200` | Matches `interactive_timeout` to avoid asymmetric disconnects |
| `innodb_lock_wait_timeout` | `60` | Reduces deadlock impact on concurrent Magento writes |
| `innodb_flush_log_at_trx_commit` | `2` | Flushes to OS buffer every second instead of per-commit; improves write throughput at minor durability risk |
| `tmp_table_size` | `{DBInstanceClassMemory/512}` | Dynamic expression based on instance memory |
| `max_heap_table_size` | `{DBInstanceClassMemory/512}` | Must match `tmp_table_size` to be effective |

---

## RabbitMQ

Affects: `aws_mq_broker`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `rabbitmq.engine_version` | string | `3.13` | RabbitMQ engine version. |
| `rabbitmq.deployment_mode` | string | `SINGLE_INSTANCE` | Amazon MQ deployment mode. `CLUSTER_MULTI_AZ` provides HA but significantly increases cost. |
| `rabbitmq.host_instance_type` | string | `mq.m5.large` | Amazon MQ host instance type. |

---

## Redis (ElastiCache)

Affects: `aws_elasticache_replication_group` (two clusters: `session` and `cache`).

The same node type, engine version, and parameters apply to both clusters. The `name` list must contain exactly `["session", "cache"]`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `redis.num_cache_clusters` | integer | `1` | Number of cache clusters (nodes) per replication group. `1` means a primary with no read replicas. Increase to `2` or `3` for read replicas and HA. |
| `redis.node_type` | string | `cache.m7g.large` | ElastiCache node type. Use Graviton-based `cache.m7g` or `cache.r7g` types. |
| `redis.name` | list of string | `["session", "cache"]` | Names of the two Redis clusters. Do not change — these values are referenced by name in `elasticache.tf` and `ssm_parameterstore.tf`. |
| `redis.family` | string | `redis7` | ElastiCache parameter group family. Must match the major version of `engine_version`. |
| `redis.engine_version` | string | `7.1` | Redis engine version. |
| `redis.port` | string | `6379` | Redis port. The default `6379` is expected by Magento. |
| `redis.at_rest_encryption_enabled` | bool | `true` | Enables AES-256 encryption at rest. |
| `redis.parameters` | list of `{name, value}` | (see below) | ElastiCache parameter group overrides. |

Default Redis parameters:

| Parameter | Value | Reason |
|-----------|-------|--------|
| `cluster-enabled` | `no` | Disables Redis Cluster mode. Magento does not support Redis Cluster for session or cache backends. |
| `maxmemory-policy` | `allkeys-lfu` | Evicts least-frequently-used keys when memory is full. Appropriate for Magento's mixed cache/session usage pattern. |

---

## ALB

Affects: `aws_cloudwatch_metric_alarm` (3 alarms: `httpcode_target_5xx_count`, `httpcode_elb_5xx_count`, `alb_rps`), `aws_lb` (deletion protection).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `alb.rps_threshold` | string | `5000` | ALB request count threshold over a 2-minute window. Triggers an SNS alarm when exceeded. Used for traffic spike alerting, not rate limiting. |
| `alb.error_threshold` | string | `25` | HTTP 5xx error count threshold over a 5-minute window. Triggers SNS alarms for both target (application) errors and ALB errors. |
| `alb.enable_deletion_protection` | bool | `false` | Prevents the ALB from being deleted via Terraform or the console. Set to `true` in production. |

---

## S3

Affects: `aws_s3_bucket` (4 buckets), `aws_s3_bucket_policy`, `aws_s3_bucket_lifecycle_configuration`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `s3` | list of string | `["media", "media-optimized", "system", "backup"]` | List of S3 bucket suffixes. Bucket names are `<brand>-<codename>-<suffix>`. All four are required. Do not rename or reorder — these names are referenced directly in IAM policies, EventBridge rules, and SSM parameter store values. |

Bucket purposes:

| Bucket | Purpose |
|--------|---------|
| `media` | Magento `pub/media/` content: product images, CMS media, customer-uploaded files. Accessible by EC2 instances (read/write) and CloudFront (read via OAI). |
| `media-optimized` | Optimized (resized/converted) product images produced by imgproxy via Lambda. Primary CloudFront origin for product image requests. 365-day object expiration lifecycle rule. |
| `system` | Operational bucket: Ansible setup zips (`setup/`), release bundles (`release/`), ALB access logs (`ALB/`), CloudFront access logs (`<project>-cloudfront-logs/`), SSM session logs, Lambda deployment package. |
| `backup` | Database and application backups. CodeDeploy has write access for deployment artifacts. |

All buckets are created with:
- Public access fully blocked (`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`)
- Server-side encryption: AES-256 (`aws:kms` is not used)
- `BucketOwnerPreferred` object ownership

---

## EFS

Affects: `aws_efs_access_point` (two access points on a single EFS file system).

The `efs` key contains two sub-keys: `var` and `media`. Each creates an EFS access point on the shared EFS file system with the specified POSIX ownership.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `efs.var.uid` | integer | `1001` | POSIX UID for the `var` access point. Should match the UID of the web server process user on the EC2 instances. |
| `efs.var.gid` | integer | `1002` | POSIX GID for the `var` access point. Should match the GID of the web group on EC2 instances. |
| `efs.var.permissions` | string | `2770` | POSIX permissions for the EFS `var` root directory. `2770` = setgid bit + owner rwx + group rwx. The setgid bit ensures new files in the directory inherit the group. |
| `efs.media.uid` | integer | `1001` | POSIX UID for the `media` access point. |
| `efs.media.gid` | integer | `1002` | POSIX GID for the `media` access point. |
| `efs.media.permissions` | string | `2770` | POSIX permissions for the EFS `media` root directory. |

EFS mount targets are created in every subnet. The EC2 security group is the only source allowed on NFS port 2049.

---

## WAF

Affects: `aws_wafv2_web_acl` (geo-block rule), `aws_cloudfront_distribution` (geo_restriction blacklist).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `waf.restricted_countries` | list of string | `["CN", "RU", "IR", "KP", "SD", "SY", "CU"]` | ISO 3166-1 alpha-2 country codes to block. Applied at two layers: WAF geo-match rule (priority 2) blocks traffic at the WAF level, and CloudFront geo-restriction blacklist blocks at the CDN level. Both lists are set from this single config value. |

Additional WAF rules are hardcoded and not configurable via YAML:
- IP allowlist/blocklist loaded from `waf/whitelist.csv` and `waf/blacklist.csv`
- Rate limit: 500 requests per IP per 2 minutes (global)
- Rate limit: 300 requests per IP per 2 minutes for `/media/`
- Rate limit: 300 requests per IP per 2 minutes for `/customer/`
- AWSManagedRulesCommonRuleSet
- AWSManagedRulesAmazonIpReputationList

---

## Passwords

Affects: `random_password` resources, `aws_ssm_parameter` (written as `SecureString`).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `password` | list of string | `["database", "rabbitmq", "redis", "opensearch"]` | Names of randomly generated passwords. Each entry creates a `random_password` resource (32 characters, special characters allowed). The resulting passwords are stored in SSM Parameter Store under `/<project>/<KEY>` using the uppercase credential key names defined in `ssm_parameterstore.tf`. Do not change this list — the names are referenced by service configurations. |

---

## Strings

Affects: `random_string` resources, `aws_ssm_parameter`, CloudFront cache behaviors, ALB health check, admin path.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `string` | list of string | `["admin_path", "health_check", "opensearch"]` | Names of randomly generated alphanumeric strings (16 characters by default). Each creates a `random_string` resource. `admin_path` is appended to `admin_` to form the Magento admin URL path and the CloudFront cache behavior path pattern. `health_check` is the ALB target group health check path. `opensearch` is used as the OpenSearch master username. Do not change this list. |

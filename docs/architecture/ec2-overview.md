# Architecture Overview — EC2 Auto Scaling Cluster

This project deploys a production-grade Magento 2 infrastructure on AWS using two EC2 Auto Scaling Groups running on ARM Graviton (`c7g` family) instances. A Varnish caching tier sits between the ALB and the PHP application tier. All instance management — software installation, configuration, and application releases — is performed without SSH using SSM Automation documents. Configuration is YAML-driven and workspace-aware, supporting independent `developer`, `staging`, and `production` environments from a single codebase.

---

## Architecture Diagram

```
                         Internet
                            |
                     +-----------+
                     | CloudFront |  WAF (geo-block, rate-limit, IP sets,
                     |  CDN+WAF   |  AWSManagedRulesCommonRuleSet)
                     +-----------+
                       |       |
            /media/catalog/   all other requests
            product/*         (default + /admin_*)
                |                    |
        +---------------+    +---------------+
        | Origin Group  |    |      ALB      |  HTTPS 443 (TLS 1.3)
        | S3 media-opt  |    | (HTTPS only)  |  HTTP 80 -> 301 redirect
        |  (primary)    |    +---------------+
        | Lambda imgprx |           |
        |  (failover)   |    listener rule: host=domain
        +---------------+    + X-Magenx-Header match
                                    |
                           +----------------+
                           |  Varnish ASG   |  c7g.large  (min 2, max 8)
                           |  (cache tier)  |  Varnish HTTP cache
                           +----------------+
                                    |
                           +----------------+
                           | Frontend ASG   |  c7g.xlarge (min 2, max 8)
                           | Nginx+PHP-FPM  |  imgproxy on port 8080
                           | + CodeDeploy   |
                           +----------------+
                            |   |   |   |   |
               +------------+   |   |   |   +----------+
               |                |   |   |              |
        +----------+   +------+ | +-------+   +--------+
        |  RDS      |   |Redis | | |Open   |   |RabbitMQ|
        |MariaDB    |   |      | | |Search |   |Amazon  |
        |10.11      |   |sess  | | |2.x    |   |MQ 3.13 |
        +----------+   |cache | | +-------+   +--------+
                        +------+ |
                                 |
                    +------------+------------+
                    |                         |
               +---------+             +-----------+
               |   EFS   |             |    S3     |
               |var/ mnt |             | media     |
               |media/mnt|             | media-opt |
               +---------+             | system    |
                                       | backup    |
                                       +-----------+
```

---

## Traffic Flow

### Standard Storefront Request

1. The browser makes an HTTPS request to the domain.
2. CloudFront receives the request. WAF rules are evaluated first: IP allowlist/blocklist (priority 0/1), geo-block (priority 2), rate-limit 500 req/2 min per IP (priority 3), AWSManagedRulesCommonRuleSet (priority 6), AWSManagedRulesAmazonIpReputationList (priority 7).
3. The default cache behavior forwards the request to the ALB origin. CloudFront adds a shared secret header (`X-Magenx-Header`) to authenticate the request.
4. The ALB HTTPS listener evaluates listener rules. Rule priority 30 matches requests with the correct host header and `X-Magenx-Header` value, forwarding to the Varnish target group.
5. A Varnish instance processes the request. On a cache hit it responds directly. On a cache miss it makes an HTTP request to a frontend instance (discovered via Cloud Map private DNS namespace `<brand>.internal`).
6. The frontend instance runs Nginx, which passes the request to PHP-FPM. PHP-FPM executes the Magento application, reads from RDS, Redis, and OpenSearch as needed, and returns the response.
7. The response traverses back through Varnish (which caches it), ALB, and CloudFront (which may cache it), to the browser.

### Admin Panel Request

The admin path is randomized at deploy time (`admin_<random_string>`). CloudFront has a dedicated ordered cache behavior matching this path pattern that bypasses caching (`CachingDisabled` policy) and uses `Managed-AllViewer` origin request policy to forward all headers. The request goes directly to the ALB → Varnish → Frontend without CloudFront caching.

---

## Image Optimization Flow

Product images under `/media/catalog/product/*` follow a specialized path:

1. CloudFront matches the ordered cache behavior for `/media/catalog/product/*`.
2. A CloudFront Function (`<project>-urlrewrite`, runtime `cloudfront-js-2.0`) rewrites the viewer request URL to normalize image paths and append optimization parameters.
3. CloudFront first attempts to serve from the `media-optimized` S3 bucket (the primary origin in the origin group). On a `403`, `404`, `500`, `503`, or `504` response it fails over to the Lambda origin.
4. The Lambda function (`<project>-image-optimization`, Node.js 20.x, deployed to `us-east-1`) acts as an imgproxy router. It reads the original image from the `media` S3 bucket, constructs an imgproxy URL, and forwards the request to `http://<ALB>:8080`.
5. The ALB forwards port 8080 traffic to the frontend ASG. imgproxy runs on port 8080 on each frontend instance and processes the resize/format conversion request.
6. The Lambda writes the optimized image to the `media-optimized` S3 bucket, then returns the response.
7. Subsequent requests for the same image are served directly from `media-optimized` (cache hit on the S3 primary origin). The `media-optimized` bucket has a 365-day lifecycle expiration policy to prevent unbounded storage growth.
8. CloudFront caches the response for up to 1 year (`max_ttl = 31536000`). Cache key includes all query strings but no cookies or headers.

---

## Instance Lifecycle

### Launch

1. ASG launches a new EC2 instance using the launch template for the instance type (`frontend` or `varnish`).
2. The `user_data` script removes the default AWS CLI v1 package and installs the SSM Agent from the official Debian ARM64 package. IMDSv2 is enforced (`http_tokens = required`) and instance metadata tags are enabled.
3. The SSM Association `InitEC2-<project>-<instance>-asg` detects the new instance (target: `tag:aws:autoscaling:groupName`) and starts the `<project>-InstanceInitialization` automation document.

### Initialization Steps (SSM Automation)

| Step | Action |
|------|--------|
| WaitForInstanceStateRunning | Polls EC2 DescribeInstanceStatus until state = `running` (timeout 300 s) |
| AssertInstanceStateRunning | Asserts state = `running` |
| WaitForInstanceStatusOk | Polls DescribeInstanceStatus until status = `ok` (timeout 300 s) |
| WriteHelperScripts | Writes `/usr/local/bin/parameterstore`, `/usr/local/bin/metadata`, `/usr/local/bin/leader` |
| InstallBasePackages | apt update; installs jq, curl, unzip, snmp, syslog-ng, pipx, AWS CLI v2, CloudWatch Agent; frontend only: installs ruby and CodeDeploy agent; sets hostname to `<instance_name>.<brand>.internal`; starts CloudWatch Agent with SSM-managed config |
| InstanceConfiguration | Installs Ansible Core via pipx; syncs setup zip from S3; runs Ansible playbook |
| GetCloudMapServiceIdFromInstanceTag | Reads `CloudmapId` EC2 tag from the instance |
| GetInstancePrivateIp | Reads private IPv4 from EC2 metadata |
| RegisterInstanceInCloudMap | Calls `servicediscovery:RegisterInstance` with the private IP |
| WaitCloudMapOperationStatus | Waits for Cloud Map operation to reach `SUCCESS` |
| SendExecutionLog | Publishes SNS notification with instance ID, IP, and Cloud Map status |

### Termination

When ASG terminates an instance (scale-in or instance replacement), an EventBridge rule matching `autoscaling:EC2_INSTANCE_TERMINATING` lifecycle events fires the `<project>-CloudMapDeregister` SSM document, which removes the instance from Cloud Map before the instance is terminated.

---

## Release Deployment Flow

1. A Magento application release is packaged as a zip file containing `appspec.yml` and deployment lifecycle scripts.
2. The zip is uploaded to the `system` S3 bucket under the `release/` prefix.
3. An EventBridge rule (`<project>-s3-release-update`) matches the S3 Object Created event for the `release/` prefix and triggers the `<project>-LatestReleaseDeployment` SSM Automation document.
4. The SSM document calls `codedeploy:CreateDeployment` with the S3 revision pointing to the uploaded zip.
5. CodeDeploy deploys the revision to all `InService` instances in the frontend ASG using the `CodeDeployDefault.AllAtOnce` deployment configuration.
6. CodeDeploy publishes deployment lifecycle notifications (start, success, failure) to the project SNS topic.
7. An SNS notification is also published by the SSM document with the deployment ID and start time.

Deployment can also be triggered manually — see [Deploying Releases](../operations/deploying-releases.md).

---

## Data Layer

| Service | Purpose |
|---------|---------|
| RDS MariaDB 10.11 | Primary Magento database. `db.m7g.large` by default. Parameters tuned for Magento workloads: `max_allowed_packet` 256 MB, extended timeouts, `innodb_flush_log_at_trx_commit=2` for write performance. Connection count is derived from instance class memory to avoid exhausting the connection pool. |
| ElastiCache Redis 7.1 (`session`) | Magento session storage. Separate cluster prevents session eviction from cache pressure. `maxmemory-policy: allkeys-lfu`. Encryption at rest enabled. |
| ElastiCache Redis 7.1 (`cache`) | Magento full-page cache (FPC) and block cache. Same node type and parameters as session cluster. Reader endpoint exposed for read-only cache lookups. |
| OpenSearch 2.x | Magento catalog search (replaces Elasticsearch). `m6g.large.search` by default, single-node. Application logs forwarded to CloudWatch. |
| Amazon MQ RabbitMQ 3.13 | Magento async message queue (consumer processes, order processing). `SINGLE_INSTANCE` deployment on `mq.m5.large`. |

---

## EFS Mounts

Two EFS access points are created from a single EFS file system:

| Mount | Path | Purpose |
|-------|------|---------|
| `var` | `/var` on EFS | Magento `var/` directory: reports, generated code compiled per release are excluded from this mount, but session files (if not using Redis) and other runtime files land here. Shared across all frontend instances to avoid split-brain on var directory writes. |
| `media` | `/media` on EFS | Magento `pub/media/` directory: product images, CMS media, customer-uploaded files. Shared across all frontend instances so uploads made to one instance are immediately visible to others. Both mounts use uid `1001`, gid `1002`, permissions `2770` (setgid bit ensures new files inherit the group). |

EFS mount targets are created in every subnet in the VPC. Security group rules restrict NFS (port 2049) access to the EC2 security group only.

---

## Security Model

### No SSH Access

There are no SSH keys or SSH-accessible security group rules. All interactive access to instances is via AWS Systems Manager Session Manager. The IAM instance profile attached to all EC2 instances includes `AmazonSSMManagedInstanceCore`.

To start a session:

```bash
aws ssm start-session --target <instance-id>
```

### Secrets Management

All passwords and credentials are stored in SSM Parameter Store. Randomly generated passwords (`random_password`) are created by Terraform for:
- `database` — RDS MariaDB
- `rabbitmq` — Amazon MQ
- `redis` — ElastiCache auth token
- `opensearch` — OpenSearch master password

All are stored as `String` type parameters under `/<project>/<KEY>`. The `/usr/local/bin/parameterstore` helper script on each instance retrieves them using the instance's IAM role.

Infrastructure connection strings, endpoints, ARNs, and configuration values (40+ parameters) are also written to SSM Parameter Store, making all configuration available to Ansible playbooks without hardcoding.

### WAF Rules (CloudFront scope, us-east-1)

| Priority | Rule | Action |
|----------|------|--------|
| 0 | IP allowlist (from `waf/whitelist.csv`) | Allow |
| 1 | IP blocklist (from `waf/blacklist.csv`) | Block |
| 2 | Geo-block: countries in `waf.restricted_countries` | Block |
| 3 | Rate limit: 500 requests / 2 min per IP | Block |
| 4 | Rate limit `/media/`: 300 requests / 2 min per IP | Block |
| 5 | Rate limit `/customer/`: 300 requests / 2 min per IP | Block |
| 6 | AWSManagedRulesCommonRuleSet | Count/Block |
| 7 | AWSManagedRulesAmazonIpReputationList | Count/Block |

CloudFront geo-restriction (blacklist) mirrors `waf.restricted_countries` as a secondary layer.

### Network Isolation

- EC2 instances have public IPs (required for SSM and package downloads) but are protected by security groups that only allow traffic from the ALB security group on application ports.
- All managed services (RDS, ElastiCache, OpenSearch, Amazon MQ, EFS) are accessible only from the EC2 security group within the VPC.
- IMDSv2 is enforced on all instances (`http_tokens = required`, `http_put_response_hop_limit = 1`).
- EBS volumes are encrypted at rest. RDS storage is encrypted. ElastiCache encryption at rest is enabled.

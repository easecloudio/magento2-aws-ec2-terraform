


//////////////////////////////////////////////////////////[ OUTPUTS ]//////////////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Network
# # ---------------------------------------------------------------------------------------------------------------------#
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "Map of availability zone to subnet ID"
  value       = { for k, v in aws_subnet.this : k => v.id }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Load balancer and CloudFront
# # ---------------------------------------------------------------------------------------------------------------------#
output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.this.dns_name
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution"
  value       = aws_cloudfront_distribution.this.id
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Auto Scaling Groups
# # ---------------------------------------------------------------------------------------------------------------------#
output "autoscaling_group_names" {
  description = "Map of instance type to ASG name"
  value       = { for k, v in aws_autoscaling_group.this : k => v.name }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Database
# # ---------------------------------------------------------------------------------------------------------------------#
output "rds_endpoint" {
  description = "RDS instance endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "rds_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.this.identifier
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Cache
# # ---------------------------------------------------------------------------------------------------------------------#
output "elasticache_primary_endpoints" {
  description = "Map of Redis cluster name to primary endpoint address"
  value       = { for k, v in aws_elasticache_replication_group.this : k => v.primary_endpoint_address }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Search
# # ---------------------------------------------------------------------------------------------------------------------#
output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint"
  value       = aws_opensearch_domain.this.endpoint
}

output "opensearch_dashboard_endpoint" {
  description = "OpenSearch Dashboards endpoint"
  value       = aws_opensearch_domain.this.dashboard_endpoint
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Message queue
# # ---------------------------------------------------------------------------------------------------------------------#
output "rabbitmq_broker_id" {
  description = "Amazon MQ broker ID"
  value       = aws_mq_broker.this.id
}

output "rabbitmq_endpoints" {
  description = "RabbitMQ broker AMQPS endpoints"
  value       = aws_mq_broker.this.instances[*].endpoints
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Storage
# # ---------------------------------------------------------------------------------------------------------------------#
output "s3_bucket_names" {
  description = "Map of bucket key to bucket name"
  value       = { for k, v in aws_s3_bucket.this : k => v.bucket }
}

output "efs_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.this.id
}

output "efs_dns_name" {
  description = "EFS file system DNS name"
  value       = aws_efs_file_system.this.dns_name
}

# # ---------------------------------------------------------------------------------------------------------------------#
# DNS and certificates
# # ---------------------------------------------------------------------------------------------------------------------#
output "route53_zone_id" {
  description = "Route 53 hosted zone ID"
  value       = aws_route53_zone.main.id
}

output "route53_name_servers" {
  description = "Route 53 name servers for the hosted zone"
  value       = aws_route53_zone.main.name_servers
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Notifications
# # ---------------------------------------------------------------------------------------------------------------------#
output "sns_topic_arn" {
  description = "ARN of the default SNS notification topic"
  value       = aws_sns_topic.default.arn
}

# # ---------------------------------------------------------------------------------------------------------------------#
# SSM
# # ---------------------------------------------------------------------------------------------------------------------#
output "ssm_parameter_prefix" {
  description = "SSM Parameter Store path prefix used for all project parameters"
  value       = "/${local.project}"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Project
# # ---------------------------------------------------------------------------------------------------------------------#
output "project_name" {
  description = "Computed project name (brand-codename)"
  value       = local.project
}

output "environment" {
  description = "Active Terraform workspace / environment name"
  value       = local.environment
}


///////////////////////////////////////////////////////////[ LOCALS ]/////////////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Load YAML config for current workspace
# # ---------------------------------------------------------------------------------------------------------------------#
locals {
  environment = lower(terraform.workspace)

  config_files = {
    developer  = try(file("${abspath(path.root)}/developer.config.yaml"), "")
    staging    = try(file("${abspath(path.root)}/staging.config.yaml"), "")
    production = try(file("${abspath(path.root)}/production.config.yaml"), "")
  }

  env     = yamldecode(local.config_files[local.environment])
  project = lower("${local.env.brand}-${local.env.codename}")

  default_tags = {
    Terraform   = true
    Brand       = local.env.brand
    Environment = local.environment
    Project     = local.project
  }

  db_name = replace(local.project, "-", "_")
}

# # ---------------------------------------------------------------------------------------------------------------------#
# WAF IP sets loaded from CSV files
# # ---------------------------------------------------------------------------------------------------------------------#
locals {
  whitelist_ips = csvdecode(file("${abspath(path.root)}/waf/whitelist.csv"))
  blacklist_ips = csvdecode(file("${abspath(path.root)}/waf/blacklist.csv"))

  waf_ipset = {
    whitelist = {
      name        = "${local.project}-whitelist-ip-set"
      description = "IP set for whitelisted IP addresses"
      addresses   = local.whitelist_ips[*].ip_address
    }
    blacklist = {
      name        = "${local.project}-blacklist-ip-set"
      description = "IP set for blacklisted IP addresses"
      addresses   = local.blacklist_ips[*].ip_address
    }
  }

  waf_ipset_rules = {
    allow-whitelisted-ips = {
      priority    = 0
      action      = "allow"
      ip_set_key  = "whitelist"
      metric_name = "${local.project}-allow-whitelisted-ips"
    }
    block-blacklisted-ips = {
      priority    = 1
      action      = "block"
      ip_set_key  = "blacklist"
      metric_name = "${local.project}-block-blacklisted-ips"
    }
  }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# AZ letter → subnet offset lookup (used in vpc_network.tf)
# # ---------------------------------------------------------------------------------------------------------------------#
locals {
  az_number = {
    a = 0
    b = 1
    c = 2
    d = 3
    e = 4
    f = 5
    g = 6
  }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# RDS instance class lookup tables (connection count + memory)
# # ---------------------------------------------------------------------------------------------------------------------#
locals {
  max_connection_count = {
    "db.m7g.large"    = 683
    "db.m7g.xlarge"   = 1365
    "db.r7g.large"    = 1365
    "db.m7g.2xlarge"  = 2731
    "db.r7g.xlarge"   = 2731
    "db.m7g.4xlarge"  = 5461
    "db.r7g.2xlarge"  = 5461
    "db.m7g.8xlarge"  = 10923
    "db.r7g.4xlarge"  = 10923
    "db.m7g.12xlarge" = 16384
    "db.m7g.16xlarge" = 21845
    "db.r7g.8xlarge"  = 21845
    "db.r7g.12xlarge" = 32768
    "db.r7g.16xlarge" = 43691
  }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# EC2 instance profile and EventBridge IAM policies
# # ---------------------------------------------------------------------------------------------------------------------#
locals {
  ec2_instance_profile_policy = [
    "arn:aws:iam::aws:policy/AWSCloudMapRegisterInstanceAccess",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess",
  ]
  eventbridge_policy = [
    "arn:aws:iam::aws:policy/service-role/CloudWatchEventsBuiltInTargetExecutionAccess",
    "arn:aws:iam::aws:policy/service-role/CloudWatchEventsInvocationAccess",
    "arn:aws:iam::aws:policy/service-role/AmazonSSMAutomationRole",
  ]
}

# # ---------------------------------------------------------------------------------------------------------------------#
# CloudFront Origin Shield region mappings
# # ---------------------------------------------------------------------------------------------------------------------#
locals {
  rec_regions = {
    US_EAST_2      = "us-east-2"
    US_EAST_1      = "us-east-1"
    US_WEST_2      = "us-west-2"
    AP_SOUTH_1     = "ap-south-1"
    AP_NORTHEAST_2 = "ap-northeast-2"
    AP_SOUTHEAST_1 = "ap-southeast-1"
    AP_SOUTHEAST_2 = "ap-southeast-2"
    AP_NORTHEAST_1 = "ap-northeast-1"
    EU_CENTRAL_1   = "eu-central-1"
    EU_WEST_1      = "eu-west-1"
    EU_WEST_2      = "eu-west-2"
    SA_EAST_1      = "sa-east-1"
  }
  other_regions = {
    US_WEST_1    = "us-west-1"
    AF_SOUTH_1   = "af-south-1"
    AP_EAST_1    = "ap-east-1"
    CA_CENTRAL_1 = "ca-central-1"
    EU_SOUTH_1   = "eu-south-1"
    EU_WEST_3    = "eu-west-3"
    EU_NORTH_1   = "eu-north-1"
    ME_SOUTH_1   = "me-south-1"
  }
  region_to_origin_shield_mappings = merge(
    {
      (local.rec_regions.US_EAST_2)      = local.rec_regions.US_EAST_2
      (local.rec_regions.US_EAST_1)      = local.rec_regions.US_EAST_1
      (local.rec_regions.US_WEST_2)      = local.rec_regions.US_WEST_2
      (local.rec_regions.AP_SOUTH_1)     = local.rec_regions.AP_SOUTH_1
      (local.rec_regions.AP_NORTHEAST_2) = local.rec_regions.AP_NORTHEAST_2
      (local.rec_regions.AP_SOUTHEAST_1) = local.rec_regions.AP_SOUTHEAST_1
      (local.rec_regions.AP_SOUTHEAST_2) = local.rec_regions.AP_SOUTHEAST_2
      (local.rec_regions.AP_NORTHEAST_1) = local.rec_regions.AP_NORTHEAST_1
      (local.rec_regions.EU_CENTRAL_1)   = local.rec_regions.EU_CENTRAL_1
      (local.rec_regions.EU_WEST_1)      = local.rec_regions.EU_WEST_1
      (local.rec_regions.EU_WEST_2)      = local.rec_regions.EU_WEST_2
      (local.rec_regions.SA_EAST_1)      = local.rec_regions.SA_EAST_1
    },
    {
      (local.other_regions.US_WEST_1)    = local.rec_regions.US_WEST_2
      (local.other_regions.AF_SOUTH_1)   = local.rec_regions.EU_WEST_1
      (local.other_regions.AP_EAST_1)    = local.rec_regions.AP_SOUTHEAST_1
      (local.other_regions.CA_CENTRAL_1) = local.rec_regions.US_EAST_1
      (local.other_regions.EU_SOUTH_1)   = local.rec_regions.EU_CENTRAL_1
      (local.other_regions.EU_WEST_3)    = local.rec_regions.EU_WEST_2
      (local.other_regions.EU_NORTH_1)   = local.rec_regions.EU_WEST_2
      (local.other_regions.ME_SOUTH_1)   = local.rec_regions.AP_SOUTH_1
    }
  )
  origin_shield_region = lookup(local.region_to_origin_shield_mappings, data.aws_region.current.name, null)
}

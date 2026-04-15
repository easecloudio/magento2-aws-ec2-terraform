


///////////////////////////////////////////////////[ RANDOM STRING GENERATOR ]////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Generate random uuid string that is intended to be used as secret header
# # ---------------------------------------------------------------------------------------------------------------------#
resource "random_uuid" "this" {}
# # ---------------------------------------------------------------------------------------------------------------------#
# Generate random passwords
# # ---------------------------------------------------------------------------------------------------------------------#
resource "random_password" "this" {
  for_each         = toset(local.env.password)
  length           = 16
  lower            = true
  upper            = true
  numeric          = true
  special          = true
  override_special = "!&#$"
}
# # ---------------------------------------------------------------------------------------------------------------------#
# Generate random string
# # ---------------------------------------------------------------------------------------------------------------------#
resource "random_string" "this" {
  for_each = toset(local.env.string)
  length   = 7
  lower    = true
  numeric  = true
  special  = false
  upper    = false
}
# # ---------------------------------------------------------------------------------------------------------------------#
# Generate random stirng for s3
# # ---------------------------------------------------------------------------------------------------------------------#
resource "random_string" "s3" {
  for_each = toset(local.env.s3)
  length   = 7
  lower    = true
  numeric  = true
  special  = false
  upper    = false
}
# # ---------------------------------------------------------------------------------------------------------------------#
# Select random subnets for ASG as required availability_zones_qty
# # ---------------------------------------------------------------------------------------------------------------------#
resource "random_shuffle" "subnets" {
  input        = [for subnet in aws_subnet.this : subnet.id]
  result_count = local.env.vpc.availability_zones_qty
}

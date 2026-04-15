


///////////////////////////////////////////////////[ AWS CERTIFICATE MANAGER ]////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Create ssl certificate for domain and subdomains
# # ---------------------------------------------------------------------------------------------------------------------#
resource "aws_acm_certificate" "default" {
  domain_name               = local.env.domain
  subject_alternative_names = ["*.${local.env.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
  tags = {
    Name = "${local.project}-${local.env.domain}-cert"
  }
}

resource "aws_acm_certificate" "cloudfront" {
  count                     = data.aws_region.current.name == "us-east-1" ? 0 : 1
  provider                  = aws.useast1
  domain_name               = local.env.domain
  subject_alternative_names = ["*.${local.env.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
  tags = {
    Name = "${local.project}-${local.env.domain}-cert"
  }
}
# # ---------------------------------------------------------------------------------------------------------------------#
# Validate ssl certificate for domain and subdomains
# # ---------------------------------------------------------------------------------------------------------------------#
resource "aws_acm_certificate_validation" "default" {
  certificate_arn = aws_acm_certificate.default.arn
}

resource "aws_acm_certificate_validation" "cloudfront" {
  count           = data.aws_region.current.name == "us-east-1" ? 0 : 1
  provider        = aws.useast1
  certificate_arn = aws_acm_certificate.cloudfront[0].arn
}

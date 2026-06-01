# ---------------------------------------------------------------------------
# Static site hosting for the lingo web app (openlingoapp.com).
# ---------------------------------------------------------------------------
# Private S3 bucket + CloudFront (OAC) + ACM cert + Route53 aliases.
# Replaces Amplify hosting; the lingo repo's deploy.yml placeholder becomes a
# real S3 sync + CloudFront invalidation once this is applied.
#
# Apply order: shared-infra (separate repo: lichfiet/shared-infra) must be
# applied FIRST — it owns the shared CloudFront WAF and the GitHub OIDC
# provider that this file and ci_oidc.tf look up.

variable "site_domain" {
  description = "Apex domain the web app is served from"
  type        = string
  default     = "openlingoapp.com"
}

variable "shared_waf_name" {
  description = "Name of the shared CloudFront Web ACL (from the shared-infra repo)"
  type        = string
  default     = "shared-cloudfront-waf"
}

# us-east-1 alias — ACM certs for CloudFront and CLOUDFRONT-scoped WAF lookups
# must live there. Mirrors the main provider's default_tags so tagging stays
# consistent on the cert.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "open-lingo"
      Environment = var.environment
    }
  }
}

# --- Lookups ------------------------------------------------------------------

data "aws_route53_zone" "site" {
  name         = var.site_domain
  private_zone = false
}

data "aws_wafv2_web_acl" "shared" {
  provider = aws.us_east_1
  name     = var.shared_waf_name
  scope    = "CLOUDFRONT"
}

# --- TLS certificate (apex + www, DNS-validated so it auto-renews) -----------

resource "aws_acm_certificate" "site" {
  provider                  = aws.us_east_1
  domain_name               = var.site_domain
  subject_alternative_names = ["www.${var.site_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Domain = "web" }
}

resource "aws_route53_record" "site_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.site.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.site_cert_validation : r.fqdn]
}

# --- S3 bucket (private; CloudFront-only access via OAC) ---------------------
# No environment suffix — matches this module's convention (lingo-ops,
# lingo_users, etc. are not env-suffixed).

resource "aws_s3_bucket" "site" {
  bucket = "openlingoapp-site"
  tags   = { Domain = "web" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontOAC"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.site.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.site.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- CloudFront ---------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "openlingoapp-site"
  description                       = "OAC for the lingo web site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "Open Lingo Web Site"
  default_root_object = "index.html"
  aliases             = [var.site_domain, "www.${var.site_domain}"]
  price_class         = "PriceClass_100" # NA + EU only; cheapest
  web_acl_id          = data.aws_wafv2_web_acl.shared.arn

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "S3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "S3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed "CachingOptimized" policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # SPA routing: serve index.html for client-side routes.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Domain = "web" }
}

# --- DNS (apex + www, A + AAAA aliases) ---------------------------------------

resource "aws_route53_record" "site_alias" {
  for_each = {
    apex_a    = { name = var.site_domain, type = "A" }
    apex_aaaa = { name = var.site_domain, type = "AAAA" }
    www_a     = { name = "www.${var.site_domain}", type = "A" }
    www_aaaa  = { name = "www.${var.site_domain}", type = "AAAA" }
  }

  zone_id = data.aws_route53_zone.site.zone_id
  name    = each.value.name
  type    = each.value.type

  # The apex A record already exists (it points at Amplify's distribution).
  # allow_overwrite lets this apply take ownership of it and flip it to the new
  # distro instead of erroring with "record already exists".
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Outputs ------------------------------------------------------------------

output "site_url" {
  value = "https://${var.site_domain}"
}

output "site_bucket_name" {
  description = "S3 bucket the lingo deploy workflow syncs the build into (LINGO_S3_BUCKET)"
  value       = aws_s3_bucket.site.bucket
}

output "site_distribution_id" {
  description = "CloudFront distribution ID for cache invalidation (LINGO_CLOUDFRONT_DIST_ID)"
  value       = aws_cloudfront_distribution.site.id
}

output "site_cloudfront_domain" {
  description = "Raw CloudFront domain (test before/without DNS)"
  value       = aws_cloudfront_distribution.site.domain_name
}

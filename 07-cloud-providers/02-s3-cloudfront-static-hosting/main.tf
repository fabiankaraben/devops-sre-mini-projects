# ==============================================================================
# Secure Static Web Hosting: S3 + CloudFront CDN + Origin Access Control (OAC)
# ==============================================================================

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.aws_endpoint != "" ? true : false
  skip_metadata_api_check     = var.aws_endpoint != "" ? true : false
  s3_use_path_style           = var.aws_endpoint != "" ? true : false

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [1] : []
    content {
      s3         = var.aws_endpoint
      cloudfront = var.aws_endpoint
      sts        = var.aws_endpoint
      iam        = var.aws_endpoint
    }
  }

  default_tags {
    tags = var.tags
  }
}

# ------------------------------------------------------------------------------
# 1. Random Suffix for Global S3 Bucket & Distribution Uniqueness
# ------------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  bucket_name = "${var.project_name}-${random_string.suffix.result}"
  oac_name    = "${var.project_name}-oac-${random_string.suffix.result}"

  mime_types = {
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".svg"  = "image/svg+xml"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".ico"  = "image/x-icon"
    ".txt"  = "text/plain; charset=utf-8"
  }
}

# ------------------------------------------------------------------------------
# 2. Private S3 Bucket for Static Website Assets
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "website" {
  bucket        = local.bucket_name
  force_destroy = true # Facilitates clean teardown for lab & staging environments

  tags = {
    Name        = local.bucket_name
    Access      = "Private-OAC-Only"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Enforce complete public access block (Zero Public S3 Access)
resource "aws_s3_bucket_public_access_block" "website" {
  bucket = aws_s3_bucket.website.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 3. CloudFront Origin Access Control (OAC)
# ------------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = local.oac_name
  description                       = "Origin Access Control for secure S3 static website origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ------------------------------------------------------------------------------
# 4. CloudFront Function: Security Headers Injector
# ------------------------------------------------------------------------------
resource "aws_cloudfront_function" "security_headers" {
  name    = "${var.project_name}-sec-headers-${random_string.suffix.result}"
  runtime = "cloudfront-js-2.0"
  comment = "Injects HSTS, CSP, X-Frame-Options, and security headers on viewer-response"
  publish = true
  code    = file("${path.module}/functions/security-headers.js")
}

# ------------------------------------------------------------------------------
# 5. CloudFront CDN Distribution
# ------------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Secure S3 Static Website Distribution with OAC"
  default_root_object = var.default_root_object
  price_class         = var.price_class

  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.website.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "S3-${aws_s3_bucket.website.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS Managed CachingOptimized Policy ID
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.security_headers.arn
    }
  }

  # Custom Error Response: Route 404 & 403 to custom error page
  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/error.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/error.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.project_name}-cdn"
  }
}

# ------------------------------------------------------------------------------
# 6. S3 Bucket Policy: Grant Access ONLY to CloudFront via OAC
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "allow_cloudfront_oac" {
  bucket = aws_s3_bucket.website.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipalReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.website.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# 7. Automated Static Web Assets Upload
# ------------------------------------------------------------------------------
resource "aws_s3_object" "static_files" {
  for_each = fileset("${path.module}/website", "**/*")

  bucket = aws_s3_bucket.website.id
  key    = each.value
  source = "${path.module}/website/${each.value}"
  etag   = filemd5("${path.module}/website/${each.value}")

  # Dynamic Content-Type resolution
  content_type = lookup(
    local.mime_types,
    regex("\\.[^.]+$", each.value),
    "binary/octet-stream"
  )

  # Cache-Control: index.html revalidates immediately, assets cached with long TTL
  cache_control = each.value == "index.html" ? "max-age=0, must-revalidate" : "max-age=31536000, immutable"
}

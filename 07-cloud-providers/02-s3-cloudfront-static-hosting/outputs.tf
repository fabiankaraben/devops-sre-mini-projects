# ==============================================================================
# Output Values for Secure S3 & CloudFront Static Web Hosting
# ==============================================================================

output "s3_bucket_name" {
  description = "Name of the private S3 bucket hosting static website files"
  value       = aws_s3_bucket.website.id
}

output "s3_bucket_arn" {
  description = "Amazon Resource Name (ARN) of the S3 website bucket"
  value       = aws_s3_bucket.website.arn
}

output "s3_bucket_regional_domain_name" {
  description = "Regional domain name of the S3 bucket used as CloudFront origin"
  value       = aws_s3_bucket.website.bucket_regional_domain_name
}

output "s3_direct_url" {
  description = "Direct S3 endpoint URL (Should return HTTP 403 Forbidden to assert private access)"
  value       = "https://${aws_s3_bucket.website.bucket_regional_domain_name}/index.html"
}

output "cloudfront_distribution_id" {
  description = "CloudFront Distribution ID"
  value       = aws_cloudfront_distribution.cdn.id
}

output "cloudfront_distribution_arn" {
  description = "Amazon Resource Name (ARN) of the CloudFront distribution"
  value       = aws_cloudfront_distribution.cdn.arn
}

output "cloudfront_domain_name" {
  description = "CloudFront default domain name (e.g. d111111abcdef8.cloudfront.net)"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

output "cloudfront_url" {
  description = "Secure HTTPS public URL to access the hosted website via CDN"
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

output "oac_id" {
  description = "Origin Access Control (OAC) Identifier"
  value       = aws_cloudfront_origin_access_control.oac.id
}

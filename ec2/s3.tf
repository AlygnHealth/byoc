# S3 bucket for Unison Cloud native services (deployed code)
resource "aws_s3_bucket" "unison_cloud_byoc_native_services" {
  bucket_prefix = "unison-cloud-byoc-services"
  force_destroy = true

  tags = {
    Name        = "${var.cluster_name}-services"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_s3_bucket_public_access_block" "unison_cloud_byoc_native_services" {
  bucket = aws_s3_bucket.unison_cloud_byoc_native_services.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket for Unison Cloud user blobs
resource "aws_s3_bucket" "unison_cloud_byoc_blobs" {
  bucket_prefix = "unison-cloud-byoc-blobs"
  force_destroy = true

  tags = {
    Name        = "${var.cluster_name}-blobs"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_s3_bucket_public_access_block" "unison_cloud_byoc_blobs" {
  bucket = aws_s3_bucket.unison_cloud_byoc_blobs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The node policies in iam.tf grant these buckets; the template also defined
# unattached managed policies for S3 and DynamoDB here, which granted nothing.
locals {
  data_buckets = {
    services = aws_s3_bucket.unison_cloud_byoc_native_services.id
    blobs    = aws_s3_bucket.unison_cloud_byoc_blobs.id
  }
}

# Both buckets encrypted at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  for_each = local.data_buckets
  bucket   = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Refuse any request that is not over TLS.
resource "aws_s3_bucket_policy" "tls_only" {
  for_each = local.data_buckets
  bucket   = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = ["arn:aws:s3:::${each.value}", "arn:aws:s3:::${each.value}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.unison_cloud_byoc_native_services,
    aws_s3_bucket_public_access_block.unison_cloud_byoc_blobs,
  ]
}

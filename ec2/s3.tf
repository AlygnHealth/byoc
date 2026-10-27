# S3 bucket for Unison Cloud native services (deployed code)
#
# Neither bucket is force_destroy: `tofu destroy` stops at a bucket that still
# holds objects instead of deleting the cluster's code and blobs with it.
# Versioning keeps an overwritten or deleted object recoverable for 30 days.
resource "aws_s3_bucket" "unison_cloud_byoc_native_services" {
  bucket_prefix = "unison-cloud-byoc-services"
  force_destroy = false

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
  force_destroy = false

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

locals {
  data_buckets = {
    services = aws_s3_bucket.unison_cloud_byoc_native_services.id
    blobs    = aws_s3_bucket.unison_cloud_byoc_blobs.id
  }
}

resource "aws_s3_bucket_versioning" "data" {
  for_each = local.data_buckets
  bucket   = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  for_each = local.data_buckets
  bucket   = each.value

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}

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

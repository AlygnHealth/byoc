# IAM role for Unison Cloud instances
resource "aws_iam_role" "unison" {
  name = "${var.cluster_name}-unison-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-unison-role"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

# S3: the services and blobs buckets only.
resource "aws_iam_role_policy" "unison_s3" {
  name = "${var.cluster_name}-unison-s3-policy"
  role = aws_iam_role.unison.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.unison_cloud_byoc_native_services.arn,
          "${aws_s3_bucket.unison_cloud_byoc_native_services.arn}/*",
          aws_s3_bucket.unison_cloud_byoc_blobs.arn,
          "${aws_s3_bucket.unison_cloud_byoc_blobs.arn}/*"
        ]
      }
    ]
  })
}

# DynamoDB: the state table only. (The template defined this as a managed
# policy and never attached it, so its nodes could not reach their table.)
resource "aws_iam_role_policy" "unison_dynamo" {
  name = "${var.cluster_name}-unison-dynamo-policy"
  role = aws_iam_role.unison.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:ConditionCheckItem",
          "dynamodb:PutItem",
          "dynamodb:DescribeTable",
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.unison_cloud_byoc_state.arn
      }
    ]
  })
}

# SSM: read the cluster token and the Vault token, nothing else.
resource "aws_iam_role_policy" "unison_ssm_parameters" {
  name = "${var.cluster_name}-unison-ssm-parameters"
  role = aws_iam_role.unison.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.cluster_token.arn,
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.vault_token_parameter}"
        ]
      }
    ]
  })
}

# CloudWatch logs, limited to this cluster's log groups.
resource "aws_iam_role_policy" "unison_cloudwatch" {
  name = "${var.cluster_name}-unison-cloudwatch-policy"
  role = aws_iam_role.unison.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/${var.cluster_name}/*"
      }
    ]
  })
}

# Session Manager in place of SSH.
resource "aws_iam_role_policy_attachment" "unison_ssm_core" {
  role       = aws_iam_role.unison.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile for Unison instances
resource "aws_iam_instance_profile" "unison" {
  name = "${var.cluster_name}-unison-profile"
  role = aws_iam_role.unison.name

  tags = {
    Name        = "${var.cluster_name}-unison-profile"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

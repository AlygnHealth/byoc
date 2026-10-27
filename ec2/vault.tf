# Vault: the store for environment config values (Environment.setValue,
# Environment.Config.lookup). nimbus keeps them in a KV v2 mount; without a
# Vault it refuses every read and write ("Vault is not configured"), and the
# template configured none.
#
# One small instance in the first private subnet, reachable only from the
# nodes, with its data on a separate encrypted EBS volume that outlives the
# instance, and auto-unseal through KMS so a restart needs nobody. After the
# first apply an operator initialises it once: `sudo vault-init` in a Session
# Manager shell on the instance (vault-cloud-init.yaml).

locals {
  vault_private_ip      = cidrhost(var.private_subnets[0], 10)
  vault_token_parameter = "/${var.cluster_name}/nimbus/vault-token"
  vault_az              = var.aws_availability_zones[0]
}

resource "aws_kms_key" "vault_unseal" {
  description             = "Auto-unseal for ${var.cluster_name}'s Vault"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name        = "${var.cluster_name}-vault-unseal"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_security_group" "vault" {
  name_prefix = "${var.cluster_name}-vault-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Vault API from the nodes"
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    security_groups = [aws_security_group.unison.id]
  }

  egress {
    description = "Outbound (KMS, image pulls, package updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-vault-sg"
    Environment = "byoc"
    Project     = "unison-cloud"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "vault" {
  name = "${var.cluster_name}-vault-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-vault-role"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_iam_role_policy" "vault_kms" {
  name = "${var.cluster_name}-vault-kms"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.vault_unseal.arn
      }
    ]
  })
}

# vault-init stores nimbus's token in SSM, and may only write that parameter.
resource "aws_iam_role_policy" "vault_ssm_parameter" {
  name = "${var.cluster_name}-vault-ssm-parameter"
  role = aws_iam_role.vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.vault_token_parameter}"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "vault_ssm_core" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vault" {
  name = "${var.cluster_name}-vault-profile"
  role = aws_iam_role.vault.name
}

resource "aws_ebs_volume" "vault_data" {
  availability_zone = local.vault_az
  size              = 10
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${var.cluster_name}-vault-data"
    Environment = "byoc"
    Project     = "unison-cloud"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "vault" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.vault_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  private_ip             = local.vault_private_ip
  vpc_security_group_ids = [aws_security_group.vault.id]
  iam_instance_profile   = aws_iam_instance_profile.vault.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/vault-cloud-init.yaml", {
    region                = data.aws_region.current.name
    kms_key_id            = aws_kms_key.vault_unseal.key_id
    volume_id             = replace(aws_ebs_volume.vault_data.id, "-", "")
    vault_image           = var.vault_image
    environments_mount    = var.environments_mount
    vault_token_parameter = local.vault_token_parameter
  })
  user_data_replace_on_change = true

  tags = {
    Name        = "${var.cluster_name}-vault"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_volume_attachment" "vault_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.vault_data.id
  instance_id = aws_instance.vault.id
}

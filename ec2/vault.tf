# Vault: the store for environment config values (Environment.setValue,
# Environment.Config.lookup). nimbus keeps them in a KV v2 mount; without a
# Vault it refuses every read and write ("Vault is not configured"), and the
# template configured none.
#
# Small instances in the first private subnet, reachable only from the nodes,
# each with its data on its own encrypted EBS volume, and auto-unseal through
# KMS so a restart needs nobody. Normally there is one server; `vault.nu update`
# adds a second on the newest image, hands it the Raft leadership and the
# address the nodes use, and removes the first, so an update has no gap of
# minutes (AlygnApp issue #389). `vault_servers` in vault-servers.auto.tfvars.json
# lists them, and only vault.nu changes it.
#
# The first server ever is initialised once: `sudo vault-init --new-cluster` in
# a Session Manager shell on it (vault-cloud-init.yaml). Every later server joins
# the existing cluster instead.

locals {
  vault_token_parameter          = "/${var.cluster_name}/nimbus/vault-token"
  vault_operator_token_parameter = "/${var.cluster_name}/vault/operator-token"
  vault_az                       = var.aws_availability_zones[0]

  # Vault's own block of the subnet, reserved so no node is ever given one of
  # its addresses: servers on .97 and .98, and the address the nodes use on .100,
  # a secondary IP that vault.nu moves to whichever server leads. The first
  # server predates the block and keeps .10 until an update replaces it.
  vault_reserved_cidr = cidrsubnet(var.private_subnets[0], 3, 6)
  vault_address       = cidrhost(local.vault_reserved_cidr, 4)
  vault_server_ips    = { for name, server in var.vault_servers : name => cidrhost(var.private_subnets[0], server.host) }

  # Until vault.nu has put the address on a server, the nodes use the first
  # server's own address.
  vault_node_address = var.vault_address_claimed ? local.vault_address : local.vault_server_ips[sort(keys(var.vault_servers))[0]]
}

resource "aws_ec2_subnet_cidr_reservation" "vault" {
  subnet_id        = module.vpc.private_subnets[0]
  cidr_block       = local.vault_reserved_cidr
  reservation_type = "explicit"
  description      = "Vault's servers and the address the nodes use"
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

  # A server joining the cluster reaches the leader's API, and a standby
  # forwards requests to the leader over the cluster port.
  ingress {
    description = "Vault API and Raft between Vault servers"
    from_port   = 8200
    to_port     = 8201
    protocol    = "tcp"
    self        = true
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
# vault.nu's commands on a server read the operator token, a token that may
# only manage Raft and step down (vault-operator-token).
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
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:GetParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.vault_operator_token_parameter}"
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
  for_each = var.vault_servers

  availability_zone = local.vault_az
  size              = 10
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${var.cluster_name}-vault-data-${each.key}"
    Environment = "byoc"
    Project     = "unison-cloud"
    Snapshot    = local.vault_snapshot_tag
  }
}

resource "aws_instance" "vault" {
  for_each = var.vault_servers

  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.vault_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  private_ip             = local.vault_server_ips[each.key]
  vpc_security_group_ids = [aws_security_group.vault.id]
  iam_instance_profile   = aws_iam_instance_profile.vault.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/vault-cloud-init.yaml", {
    region                         = data.aws_region.current.name
    kms_key_id                     = aws_kms_key.vault_unseal.key_id
    volume_id                      = replace(aws_ebs_volume.vault_data[each.key].id, "-", "")
    vault_image                    = var.vault_image
    environments_mount             = var.environments_mount
    vault_token_parameter          = local.vault_token_parameter
    vault_operator_token_parameter = local.vault_operator_token_parameter
    node_id                        = each.key
    server_ip                      = local.vault_server_ips[each.key]
  })
  user_data_replace_on_change = true

  tags = {
    Name        = "${var.cluster_name}-vault-${each.key}"
    Environment = "byoc"
    Project     = "unison-cloud"
  }

  # A newer Amazon Linux image, or any edit to the cloud-init (the Vault image
  # pin included), would otherwise replace a server on any apply, taking
  # secrets away from every node while it restarts. Servers change only through
  # `vault.nu update`, which starts a new one with the current image and
  # cloud-init and removes the old (AlygnApp issue #389).
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "vault_data" {
  for_each = var.vault_servers

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.vault_data[each.key].id
  instance_id = aws_instance.vault[each.key].id
}

# The single server from before `vault_servers`, kept where it is.
moved {
  from = aws_ebs_volume.vault_data
  to   = aws_ebs_volume.vault_data["blue"]
}

moved {
  from = aws_instance.vault
  to   = aws_instance.vault["blue"]
}

moved {
  from = aws_volume_attachment.vault_data
  to   = aws_volume_attachment.vault_data["blue"]
}

# Daily snapshots of every Vault server's data volume, kept two weeks: Raft
# copies a mistaken write to every server, and an update deletes the old
# server's volume (vault.nu snapshots it first). A snapshot restores to a new
# volume in the same AZ; the KMS key that unseals it is unchanged.
locals {
  vault_snapshot_tag = "${var.cluster_name}-vault-daily"
}

resource "aws_iam_role" "dlm" {
  name = "${var.cluster_name}-dlm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "vault" {
  description        = "${var.cluster_name} Vault data daily"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = local.vault_snapshot_tag }

    schedule {
      name      = "daily kept 14 days"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["10:00"]
      }

      retain_rule {
        count = 14
      }
    }
  }

  tags = {
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

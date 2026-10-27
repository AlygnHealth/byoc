# Security group for Unison Cloud instances
#
# Public traffic reaches a node only through the load balancer. The internal
# HTTP server (8081: health, /internal/shutdown, /internal/reload-config) and
# the peer TCP port (9091) are open to the load balancer's health check and to
# other nodes, never to the internet.
resource "aws_security_group" "unison" {
  name_prefix = "${var.cluster_name}-unison-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Service traffic from the ALB"
    from_port       = 8082
    to_port         = 8082
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Health check from the ALB"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Node to node: gossip and public HTTP"
    from_port   = 8081
    to_port     = 8082
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Node to node: peer TCP"
    from_port   = 9091
    to_port     = 9091
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-unison-sg"
    Environment = "byoc"
    Project     = "unison-cloud"
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "cloudinit_config" "unison-cloudinint" {
  part {
    merge_type   = "list(append)+dict(recurse_array)+str()"
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-init.yaml", {
      unison_cloud_image      = var.unison_cloud_image
      unison_cloud_image_tag  = var.unison_cloud_image_tag
      region                  = data.aws_region.current.name
      cluster_token_parameter = aws_ssm_parameter.cluster_token.name
      vault_token_parameter   = local.vault_token_parameter
      config_template = base64encode(templatefile("${path.module}/config.json.template", {
        blob_bucket_name     = aws_s3_bucket.unison_cloud_byoc_blobs.bucket
        services_bucket_name = aws_s3_bucket.unison_cloud_byoc_native_services.bucket
        region               = data.aws_region.current.name
        dynamodb_table       = aws_dynamodb_table.unison_cloud_byoc_state.id
        cluster_name         = var.cluster_name
        vault_host           = local.vault_private_ip
        environments_mount   = var.environments_mount
      }))
    })
  }
}

resource "aws_launch_template" "unison" {
  name_prefix   = "${var.cluster_name}-unison-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.unison_instance_type

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.unison.id]
    delete_on_termination       = true
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.unison.name
  }

  # IMDSv2 only. The hop limit of 2 lets the nimbus container itself refresh
  # the instance role's credentials, as its wrapper does every 15 minutes.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = data.cloudinit_config.unison-cloudinint.rendered

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.cluster_name}-unison"
      Environment = "byoc"
      Project     = "unison-cloud"
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.cluster_name}-unison-lt"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_autoscaling_group" "unison" {
  name                      = "${var.cluster_name}-unison-asg"
  vpc_zone_identifier       = module.vpc.private_subnets
  target_group_arns         = [aws_lb_target_group.unison.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  min_size         = var.unison_min_instances
  max_size         = var.unison_max_instances
  desired_capacity = var.unison_desired_instances

  launch_template {
    id      = aws_launch_template.unison.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-unison-asg"
    propagate_at_launch = false
  }

  tag {
    key                 = "Environment"
    value               = "byoc"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "unison-cloud"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  depends_on = [terraform_data.cluster_registration]
}

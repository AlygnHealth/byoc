# Certificate for the cluster's own name, validated by a DNS record that the
# operator adds in Cloudflare (`tofu output acm_validation_records`). `tofu
# apply` waits at aws_acm_certificate_validation until the record resolves.
resource "aws_acm_certificate" "cluster" {
  domain_name       = var.cluster_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.cluster_name}-cert"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_acm_certificate_validation" "cluster" {
  certificate_arn = aws_acm_certificate.cluster.arn

  timeouts {
    create = "2h"
  }
}

# Security group for load balancer
resource "aws_security_group" "alb" {
  name_prefix = "${var.cluster_name}-alb-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the nodes"
    from_port   = 8081
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name        = "${var.cluster_name}-alb-sg"
    Environment = "byoc"
    Project     = "unison-cloud"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = true
  drop_invalid_header_fields = true

  tags = {
    Name        = "${var.cluster_name}-alb"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

# Target group for Unison Cloud instances
resource "aws_lb_target_group" "unison" {
  name     = "${var.cluster_name}-unison-tg"
  port     = 8082
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-299"
    path                = "/health"
    port                = "8081"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name        = "${var.cluster_name}-unison-tg"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}


# ALB Listener for HTTP (redirect to HTTPS)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ALB Listener for HTTPS: TLS 1.2 and 1.3 only.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.cluster.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.unison.arn
  }
}

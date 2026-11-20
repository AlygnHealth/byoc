module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.vpc_name
  cidr = var.vpc_cidr

  azs                  = var.aws_availability_zones
  public_subnets       = var.public_subnets
  private_subnets      = var.private_subnets
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nothing here uses the default security group; it admits only its own
  # members (the template's version also admitted 0.0.0.0/0).
  default_security_group_ingress = [
    {
      "from_port" : 0,
      "to_port" : 0,
      "protocol" : -1,
      "self" : true,
    }
  ]
  default_security_group_egress = [
    {
      "from_port" : 0,
      "to_port" : 0,
      "protocol" : -1,
      "cidr_blocks" : "0.0.0.0/0",
    }
  ]

  tags = {
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

# S3 and DynamoDB through gateway endpoints rather than the NAT gateway: free,
# and the nodes' storage traffic stops paying NAT's per-gigabyte charge.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name        = "${var.cluster_name}-s3"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name        = "${var.cluster_name}-dynamodb"
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

# The nodes' container logs, which would otherwise stay on the instance and go
# with it. The nodes' role may write to this cluster's log groups (iam.tf).
resource "aws_cloudwatch_log_group" "nodes" {
  name              = "/${var.cluster_name}/nodes"
  retention_in_days = var.node_log_retention_days

  tags = {
    Environment = "byoc"
    Project     = "unison-cloud"
  }
}

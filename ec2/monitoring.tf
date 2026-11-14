# One CloudWatch dashboard for the cluster, and the memory and disk figures
# EC2 does not report by itself, all inside CloudWatch's free tier (3
# dashboards, 10 custom metrics a month).
#
# The CloudWatch agent on each node and Vault server reports memory and disk
# used by role ("nodes", "vault"), not by instance: a roll or a `vault.nu
# update` then adds no new metrics, so the count stays at five (memory and the
# root disk for each role, and Vault's data disk). Where several instances
# share a role, the dashboard shows the highest. CPU stays per instance, from
# EC2's own free metrics.

locals {
  host_metrics_namespace = "${var.cluster_name}/hosts"

  # The agent's configuration for a role; `disks` are the mount points watched.
  cloudwatch_agent_config = { for role, disks in { nodes = ["/"], vault = ["/", "/opt/vault/data"] } : role => jsonencode({
    agent = {
      metrics_collection_interval = 60
      omit_hostname               = true
    }
    metrics = {
      namespace = local.host_metrics_namespace
      metrics_collected = {
        mem = {
          measurement       = ["mem_used_percent"]
          append_dimensions = { Role = role }
        }
        disk = {
          measurement       = ["used_percent"]
          resources         = disks
          drop_device       = true
          append_dimensions = { Role = role }
        }
      }
    }
  }) }
}

# The agent may only write metrics, and only to this cluster's namespace.
resource "aws_iam_role_policy" "host_metrics" {
  for_each = {
    nodes = aws_iam_role.unison.id
    vault = aws_iam_role.vault.id
  }

  name = "${var.cluster_name}-${each.key}-host-metrics"
  role = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = local.host_metrics_namespace } }
    }]
  })
}

locals {
  dashboard_region = data.aws_region.current.name
  balancer         = aws_lb.main.arn_suffix
  table            = aws_dynamodb_table.unison_cloud_byoc_state.name

  # A widget of metrics, `metrics` in the dashboard's own row form.
  dashboard_graph = { for name, graph in {
    cpu = {
      title   = "CPU % (each instance)"
      metrics = [[{ expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUUtilization\"', 'Average', 300)", id = "cpu", label = "" }]]
    }
    memory = {
      title = "Memory used %"
      metrics = [
        [local.host_metrics_namespace, "mem_used_percent", "Role", "nodes", { stat = "Maximum", label = "nodes" }],
        [local.host_metrics_namespace, "mem_used_percent", "Role", "vault", { stat = "Maximum", label = "Vault" }],
      ]
    }
    disk = {
      title   = "Disk used %"
      metrics = [[{ expression = "SEARCH('{${local.host_metrics_namespace},Role,path,fstype} MetricName=\"used_percent\"', 'Maximum', 300)", id = "disk", label = "" }]]
    }
    requests = {
      title = "Requests and errors (per 5 min)"
      metrics = [
        ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.balancer, { stat = "Sum", label = "requests" }],
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.balancer, { stat = "Sum", label = "5xx from the services" }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.balancer, { stat = "Sum", label = "5xx from the balancer" }],
      ]
    }
    latency = {
      title = "Response time (seconds)"
      metrics = [
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.balancer, { stat = "p50", label = "median" }],
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.balancer, { stat = "p99", label = "p99" }],
      ]
    }
    healthy = {
      title = "Healthy nodes"
      metrics = [
        ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.unison.arn_suffix, "LoadBalancer", local.balancer, { stat = "Minimum", label = "healthy" }],
      ]
    }
    dynamodb = {
      title = "DynamoDB capacity used (per 5 min)"
      metrics = [
        ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", local.table, { stat = "Sum", label = "writes" }],
        ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", local.table, { stat = "Sum", label = "reads" }],
      ]
    }
    } : name => {
    type   = "metric"
    width  = 8
    height = 6
    properties = {
      title   = graph.title
      region  = local.dashboard_region
      view    = "timeSeries"
      stacked = false
      period  = 300
      metrics = graph.metrics
    }
  } }
}

resource "aws_cloudwatch_dashboard" "cluster" {
  dashboard_name = var.cluster_name

  dashboard_body = jsonencode({
    widgets = concat(
      [{
        type   = "alarm"
        width  = 24
        height = 3
        properties = {
          title = "Alarms"
          alarms = concat(
            [
              aws_cloudwatch_metric_alarm.nodes_healthy.arn,
              aws_cloudwatch_metric_alarm.server_errors.arn,
              aws_cloudwatch_metric_alarm.dynamodb_throttles.arn,
              aws_cloudwatch_metric_alarm.dynamodb_errors.arn,
            ],
            [for alarm in aws_cloudwatch_metric_alarm.vault_host : alarm.arn],
            [for alarm in aws_cloudwatch_metric_alarm.vault_instance : alarm.arn],
          )
        }
      }],
      [for name in ["requests", "latency", "healthy", "cpu", "memory", "disk", "dynamodb"] : local.dashboard_graph[name]],
      [{
        type   = "text"
        width  = 8
        height = 6
        properties = {
          markdown = "**Spend**: [Cost Explorer](https://us-east-1.console.aws.amazon.com/costmanagement/home#/cost-explorer), by service or by day; [Budgets](https://us-east-1.console.aws.amazon.com/costmanagement/home#/budgets).\n\n**Logs**: [/${var.cluster_name}/nodes](https://${local.dashboard_region}.console.aws.amazon.com/cloudwatch/home?region=${local.dashboard_region}#logsV2:log-groups/log-group/$252F${var.cluster_name}$252Fnodes)"
        }
      }],
    )
  })
}

output "dashboard_url" {
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards/dashboard/${var.cluster_name}"
  description = "The cluster's CloudWatch dashboard"
}

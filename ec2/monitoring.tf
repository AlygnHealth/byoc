# One CloudWatch dashboard for the cluster, and the memory and disk figures
# EC2 does not report by itself, all inside CloudWatch's free tier (3
# dashboards, 10 custom metrics a month).
#
# The CloudWatch agent on each node and Vault server reports memory and disk
# used by role ("nodes", "vault"), and a node also by its availability zone,
# not by instance: a roll or a `vault.nu update` then adds no new metrics. The
# group keeps one node in each zone, so a zone names a node and the dashboard
# can show each one. That makes seven metrics: memory and the root disk for
# each zone's node, and for Vault, plus Vault's data disk. CPU stays per
# instance, from EC2's own free metrics.

locals {
  host_metrics_namespace = "${var.cluster_name}/hosts"

  # What each role's agent watches: the mount points, and whether it names its
  # zone. The agent cannot read the zone itself, so a node's cloud-init puts it
  # in place of `host_metrics_zone_placeholder` from the instance metadata.
  host_metrics_roles = {
    nodes = { disks = ["/"], by_zone = true }
    vault = { disks = ["/", "/opt/vault/data"], by_zone = false }
  }
  host_metrics_zone_placeholder = "AVAILABILITYZONE"

  # The dimensions every metric of a role carries.
  host_metrics_dimensions = { for role, watch in local.host_metrics_roles : role => merge(
    { Role = role },
    { for key, value in { Zone = local.host_metrics_zone_placeholder } : key => value if watch.by_zone },
  ) }

  # The agent's configuration for a role.
  cloudwatch_agent_config = { for role, watch in local.host_metrics_roles : role => jsonencode({
    agent = {
      metrics_collection_interval = 60
      omit_hostname               = true
    }
    metrics = {
      namespace = local.host_metrics_namespace
      metrics_collected = {
        mem = {
          measurement       = ["mem_used_percent"]
          append_dimensions = local.host_metrics_dimensions[role]
        }
        disk = {
          measurement       = ["used_percent"]
          resources         = watch.disks
          drop_device       = true
          append_dimensions = local.host_metrics_dimensions[role]
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
    # One line per node (by zone) and one for Vault. A search with no schema
    # matches every set of dimensions, and returns only metrics written in the
    # last two weeks, so the old by-role node lines drop out by themselves.
    memory = {
      title   = "Memory used % (each node, and Vault)"
      metrics = [[{ expression = "SEARCH('Namespace=\"${local.host_metrics_namespace}\" MetricName=\"mem_used_percent\"', 'Maximum', 300)", id = "memory", label = "" }]]
    }
    disk = {
      title   = "Disk used % (each node, and Vault's two)"
      metrics = [[{ expression = "SEARCH('Namespace=\"${local.host_metrics_namespace}\" MetricName=\"used_percent\"', 'Maximum', 300)", id = "disk", label = "" }]]
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
            [for alarm in aws_cloudwatch_metric_alarm.node_memory : alarm.arn],
            [for alarm in aws_cloudwatch_metric_alarm.host_disk : alarm.arn],
            [aws_cloudwatch_metric_alarm.vault_memory.arn],
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

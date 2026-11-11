# Alerts, by email: one SNS topic for the alarms here, and a budget that writes
# directly. An email subscription stays pending until its link is clicked, and
# a pending address hears nothing.

resource "aws_sns_topic" "alerts" {
  name = "${var.cluster_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# DynamoDB and S3 have no ceiling of their own, so this is the only warning of
# a runaway bill. Budgets cover the whole account.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [var.budget_warning_percent, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

# A roll takes one node out at a time for a few minutes, so ten minutes below
# strength means a node that is not coming back.
resource "aws_cloudwatch_metric_alarm" "nodes_healthy" {
  alarm_name          = "${var.cluster_name}-nodes-healthy"
  alarm_description   = "Fewer healthy nodes behind the load balancer than unison_desired_instances, for ten minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  comparison_operator = "LessThanThreshold"
  threshold           = var.unison_desired_instances
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.unison.arn_suffix
  }
}

# Below 20 requests a minute a single failure would read as a high rate.
resource "aws_cloudwatch_metric_alarm" "server_errors" {
  alarm_name          = "${var.cluster_name}-server-errors"
  alarm_description   = "Over 5% of requests answered 5xx, for five minutes."
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "error_percent"
    expression  = "IF(FILL(requests, 0) >= 20, 100 * (FILL(balancer, 0) + FILL(service, 0)) / requests, 0)"
    label       = "5xx percent"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = {
      requests = "RequestCount"
      balancer = "HTTPCode_ELB_5XX_Count"
      service  = "HTTPCode_Target_5XX_Count"
    }
    content {
      id = metric_query.key
      metric {
        namespace   = "AWS/ApplicationELB"
        metric_name = metric_query.value
        period      = 60
        stat        = "Sum"
        dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      }
    }
  }
}

# A failed check on a Vault server also acts: AWS moves the instance off bad
# hardware (its addresses and volumes go with it) or reboots it, and Vault
# unseals itself through KMS. One pair per server, so an update's second server
# is watched too.
resource "aws_cloudwatch_metric_alarm" "vault_host" {
  for_each = aws_instance.vault

  alarm_name          = "${var.cluster_name}-vault-host-${each.key}"
  alarm_description   = "Vault server ${each.key}'s host failed its system status check; recovering the instance."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  alarm_actions       = ["arn:aws:automate:${data.aws_region.current.name}:ec2:recover", aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = { InstanceId = each.value.id }
}

resource "aws_cloudwatch_metric_alarm" "vault_instance" {
  for_each = aws_instance.vault

  alarm_name          = "${var.cluster_name}-vault-instance-${each.key}"
  alarm_description   = "Vault server ${each.key}'s instance failed its status check; rebooting it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  alarm_actions       = ["arn:aws:automate:${data.aws_region.current.name}:ec2:reboot", aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = { InstanceId = each.value.id }
}

locals {
  dynamodb_dimensions = { TableName = aws_dynamodb_table.unison_cloud_byoc_state.id }
  dynamodb_operations = ["GetItem", "PutItem", "UpdateItem", "DeleteItem", "Query", "BatchGetItem", "BatchWriteItem", "TransactGetItems", "TransactWriteItems"]
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${var.cluster_name}-dynamodb-throttles"
  alarm_description   = "DynamoDB throttled reads or writes for five minutes."
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "throttles"
    expression  = "FILL(reads, 0) + FILL(writes, 0)"
    label       = "Throttle events"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = { reads = "ReadThrottleEvents", writes = "WriteThrottleEvents" }
    content {
      id = metric_query.key
      metric {
        namespace   = "AWS/DynamoDB"
        metric_name = metric_query.value
        period      = 60
        stat        = "Sum"
        dimensions  = local.dynamodb_dimensions
      }
    }
  }
}

# DynamoDB reports system errors per operation, so the alarm adds them up.
resource "aws_cloudwatch_metric_alarm" "dynamodb_errors" {
  alarm_name          = "${var.cluster_name}-dynamodb-errors"
  alarm_description   = "DynamoDB answered with system errors for three minutes."
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "errors"
    expression  = "SUM(FILL(METRICS(), 0))"
    label       = "System errors"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.dynamodb_operations
    content {
      id = lower(metric_query.value)
      metric {
        namespace   = "AWS/DynamoDB"
        metric_name = "SystemErrors"
        period      = 60
        stat        = "Sum"
        dimensions  = merge(local.dynamodb_dimensions, { Operation = metric_query.value })
      }
    }
  }
}

# Registers the cluster with the control plane, points it at this cluster's
# load balancer, and makes the nodes' token.
#
# The template did this with `data "http"` sources. Those run on every plan,
# so each plan minted a new token (the control plane keeps only the two
# newest, so the third plan cut off running nodes), and they kept both the
# token and the operator's Unison access token in OpenTofu state.
#
# Here it runs once, as a provisioner: the token goes straight into SSM
# Parameter Store and is never printed or kept in state. Change
# `cluster_token_generation` to make a new token; instances started after the
# change pick it up, so follow it with an instance refresh.
resource "aws_ssm_parameter" "cluster_token" {
  name        = "/${var.cluster_name}/nimbus/cluster-token"
  description = "Unison Cloud BYOC node token for ${var.cluster_name}, written by cluster.tf"
  type        = "SecureString"
  value       = "unset"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "terraform_data" "cluster_registration" {
  triggers_replace = [
    var.cluster_name,
    var.cluster_domain,
    var.cluster_token_generation,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      api=https://api.unison.cloud/v2/byoc/clusters
      auth="Authorization: Bearer $UNISON_ACCESS_TOKEN"
      cluster_id=$(curl -fsS -X POST -H "$auth" "$api/$CLUSTER_NAME")
      curl -fsS -X POST -H "$auth" -H 'Content-Type: application/json' \
        --data "\"https://$CLUSTER_DOMAIN\"" "$api/$cluster_id/clusterUri" > /dev/null
      curl -fsS -X POST -H "$auth" "$api/$cluster_id/token" \
        | aws ssm put-parameter --region "$AWS_REGION" --name "$PARAMETER" \
            --type SecureString --overwrite --value file:///dev/stdin > /dev/null
      echo "Registered $CLUSTER_NAME ($cluster_id) at https://$CLUSTER_DOMAIN; node token stored in $PARAMETER."
    EOT
    environment = {
      UNISON_ACCESS_TOKEN = local.unison_token
      CLUSTER_NAME        = var.cluster_name
      CLUSTER_DOMAIN      = var.cluster_domain
      PARAMETER           = aws_ssm_parameter.cluster_token.name
      AWS_REGION          = var.aws_region
    }
  }
}

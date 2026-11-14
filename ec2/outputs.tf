output "cluster_uri" {
  value       = "https://${var.cluster_domain}"
  description = "The cluster's URI, as registered with the control plane"
}

output "load_balancer_dns_name" {
  value       = aws_lb.main.dns_name
  description = "Point cluster_domain at this name (a CNAME)"
}

output "acm_validation_records" {
  value = [
    for option in aws_acm_certificate.cluster.domain_validation_options : {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  ]
  description = "Add these DNS records (DNS only, not proxied) so ACM can issue the certificate; `tofu apply` waits for them"
}

output "vault_instance_ids" {
  value       = { for name, server in aws_instance.vault : name => server.id }
  description = "Vault's servers, by node id; `vault.nu status` says which leads and which holds the nodes' address"
}

output "vault_instance_id" {
  value       = length(aws_instance.vault) == 1 ? one(values(aws_instance.vault)).id : null
  description = "The Vault server, while there is one: `aws ssm start-session --target <this>`"
}

output "vault_address" {
  value       = local.vault_address
  description = "The address the nodes reach Vault at, once vault.nu has claimed it"
}

resource "local_file" "cluster_config_script" {
  filename = "${path.module}/outputs/cluster-config.u"
  content  = <<EOF
{{
In order to connect to your cluster, use a client config that names its API host:
}}

clusterConfig = do
  hostname = HostName "${var.cluster_name}.byoc.unison.cloud"
  Cloud.ClientConfig.default()
     |> ClientConfig.host.set hostname

-- Instead of calling Cloud.run, which, by default, targets the Unison public cluster,
-- use Cloud.run.withConfig to target your own cluster:

sampleJob = do Threads.run do Cloud.run.withConfig clusterConfig() do
    env = default()
    two = submit env do
      1 + 1
    printLine ("remotely calculated: 1 + 1 = " ++ (Nat.toText two))
EOF
}

output "cluster_config_u" {
  sensitive   = false
  description = "Unison script to connect to your cluster"
  value       = local_file.cluster_config_script.content
}

output "vault_server_ips" {
  value       = local.vault_server_ips
  description = "Each Vault server's own address, by node id"
}

output "vault_operator_token_parameter" {
  value       = local.vault_operator_token_parameter
  description = "The SSM parameter holding the token vault.nu's commands use on a server (`sudo vault-operator-token`)"
}

output "aws_region" {
  value       = data.aws_region.current.name
  description = "The region everything here is in"
}

output "vault_update_checks" {
  value       = var.vault_update_checks
  description = "What `vault.nu update` checks before it starts and after the handover"
}

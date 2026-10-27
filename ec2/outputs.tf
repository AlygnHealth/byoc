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

output "vault_instance_id" {
  value       = aws_instance.vault.id
  description = "Run `aws ssm start-session --target <this>`, then `sudo vault-init`, once after the first apply"
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

sampleJob = do Cloud.run.withConfig clusterConfig() do
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

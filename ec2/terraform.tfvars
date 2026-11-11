aws_region             = "us-west-2"
aws_availability_zones = ["us-west-2a", "us-west-2b"]

# You must change the cluster_name before deploying. 
# The new name must consistsolely of letters, numbers, and hyphens.

cluster_name = "alygnhealth"

# The cluster's own DNS name; see variables.tf.
cluster_domain = "byoc.alygnhealth.com"

# Optional variables with default values that can be overridden.
# See varaibles.tf for descriptions:

# vpc_cidr = "10.0.0.0/16"
# public_subnets = ["10.0.20.0/25", "10.0.20.128/25"]
# private_subnets = ["10.0.30.0/25", "10.0.30.128/25"]

# Unison Cloud Configuration
# Our build of @unison/nimbus/cloudwatch-logs (../nimbus-image, 2026-11-09),
# pinned by digest: Unison's nimbus with a cloudwatch log provider, so nodes
# answer log requests from their CloudWatch log group (logs_from_cloudwatch).
# It registers with the control plane once the config has a clusterMap, which
# config.json.template supplies. The way back is Unison's 44.4.9 build,
# unisoncomputing/unison-cloud
# cloud_nimbus_releases_44_4_9_37244@sha256:1ab843e890c090d371099c1a9a08a3ecfa3216fb6e2e7eb3330c92d4a2056370,
# with logs_from_cloudwatch = false in the same apply.
unison_cloud_image     = "ghcr.io/bbarker/nimbus-share"
unison_cloud_image_tag = "2026-11-09-cwlogs@sha256:fc28c95e355006891becea23ff000d2e92da6e2132016bb6e3074d1223a34fa6"
logs_from_cloudwatch   = true
# vault_instance_type = "t3.small"
# unison_instance_type = "t3.medium"
# unison_min_instances = 1
# unison_max_instances = 8
# unison_desired_instances = 2

# What `vault.nu update` checks before it starts and after the handover: each
# must answer 200 with `"status":"ok"`, or the update goes back to the old server.
vault_update_checks = [
  "https://byoc.alygnhealth.com/services/s/bbarker/alygnhealth/api/health",
  "https://byoc.alygnhealth.com/services/s/bbarker/alygnhealth-test/api/health",
]

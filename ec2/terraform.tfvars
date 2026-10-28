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
# Unison's 44.4.9 build (pushed 2026-10-27), pinned by digest. It registers with
# the control plane once the config has a clusterMap, which config.json.template
# supplies. ../nimbus-image builds our own if a release ever lags again.
unison_cloud_image     = "unisoncomputing/unison-cloud"
unison_cloud_image_tag = "cloud_nimbus_releases_44_4_9_37244@sha256:1ab843e890c090d371099c1a9a08a3ecfa3216fb6e2e7eb3330c92d4a2056370"
# vault_instance_type = "t3.small"
# unison_instance_type = "t3.medium"
# unison_min_instances = 1
# unison_max_instances = 8
# unison_desired_instances = 2

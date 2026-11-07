# OpenTofu / Terraform definition for creating EC2 instances to run unison.cloud

# Overview

This repository contains a Terraform (or OpenTofu) definition for creating EC2 instances to run a BYOC (Bring Your Own Cloud) instance of [unison.cloud](https://unison.cloud).

## Scope

This repository creates:

- An AWS VPC with public and private subnets. [vpc.tf](vpc.tf)
- EC2 instances in an Auto Scaling Group running the unison.cloud application. [unison.tf](unison.tf)
- An Application Load Balancer for routing traffic to unison.cloud instances. [loadbalancer.tf](loadbalancer.tf)
- A Vault instance for environment config values, with its data on an encrypted EBS volume and auto-unseal through KMS. [vault.tf](vault.tf)
- A DynamoDB table for storing unison.cloud data using unison.cloud's `Storage` ability, with point-in-time recovery. [dynamo.tf](dynamo.tf)
- S3 buckets for storing unison.cloud services, and storing blobs using Unison Cloud's `Blob` storage. [s3.tf](s3.tf)
- IAM roles and policies for EC2 instances to access AWS services. [iam.tf](iam.tf)
- Email alerts: a monthly budget and CloudWatch alarms. [alerts.tf](alerts.tf)

This is intended to demonstrate a minimalist deployment of unison.cloud on EC2. It is **not production-ready** but serves testing, development, and demonstration purposes. This provides an easy way to test unison.cloud in your AWS account with EC2 instances.

# Prerequisites

- [Terraform](https://www.terraform.io) / [OpenTofu](https://opentofu.org)
    Terraform is a tool for building infrastructure declaratively. OpenTofu is a recent fork of Terraform under a more free license. This repository is compatible with both tools.

    * [Install OpenTofu](https://opentofu.org/docs/intro/install/)

- AWS CLI
    AWS CLI must be installed and configured with credentials sufficient to create all the various resources in AWS (VPCs, EC2, S3 buckets, etc.) AWS CLI can be installed following [Amazon's instructions](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions). MacOs users can also install it via Homebrew with `brew install awscli`.

    You can configure the AWS CLI by running `aws configure` and providing your AWS Access Key ID, Secret Access Key, and the default region.

<details>
<summary>Notes for Nix users</summary>
## Nix

If you use [Nix](https://nixos.org), there is a nix flake definition that installs OpenTofu and aws cli. You can launch a shell with all the tools by running `nix develop #eks` in the parent directory, or use [direnv](https://direnv.net/) with `use flake #eks` in a `.envrc` file to automatically load the environment when you `cd` into the directory.
</details>

## Deploying to AWS

### terraform.tfvars

[variables.tf](variables.tf) is where all of the variables for the deployment are defined. The values are set in [terraform.tfvars](terraform.tfvars). *You must* edit this file to set the `cluster_name` before deploying.

#### Required variables:

##### `aws_region`

The AWS region to deploy the cluster in. Examples include `us-west-2`, `us-east-1`, etc. This is the region where all the resources will be created.

You can find a complete list of zones and regions in the [AWS documentation](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-availability-zones.html).

##### `aws_availability_zones`

A list of availability zones to use for the VPC. This should be a list of two or more availability zones in the region you are deploying to. For example, `["us-west-2a", "us-west-2b"]`. You must include at least two availability zones for the load balancer to work across multiple AZs.

You can find a complete list of zones and regions in the [AWS documentation](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-availability-zones.html).

##### `cluster_name`

The name of the cluster, which should match the name you used to create a `Cluster.Id`. This will be used to name the EC2 instances and the DynamoDB table. It must be a valid DNS subdomain, meaning it must consist of only lowercase letters, numbers, and hyphens, and must start and end with a letter or number.

##### `cluster_domain`

The cluster's own DNS name, such as `byoc.example.com`, in a zone you control. The load balancer gets an ACM certificate for it, and it is registered as the cluster's URI, so clients and a CDN in front of it use ordinary TLS.

##### `unison_cloud_image` and `unison_cloud_image_tag`

The nimbus image. Images older than `cloud_nimbus_releases_44_4_9_37244` are refused by the current control plane (`key "hostname" not found`, [byoc#2](https://github.com/unisoncomputing/byoc/issues/2)), and `latest` has lagged, so name a release, by digest if you can. [`../nimbus-image`](../nimbus-image) builds a current one from the `@unison/nimbus` source if a release ever falls behind again; push it to a registry the nodes can pull from and name it here.

### Running Terraform

Once you have created the `terraform.tfvars` file, run `auth.login` in UCM (the apply registers the cluster with your Unison credentials), then:

```bash
$ tofu init
$ tofu apply
```

`tofu init` will inspect the configuration and download any necessary terraform modules.
`tofu apply` creates everything in your AWS account, which takes 15-20 minutes, and then waits for the certificate:

1. `tofu output acm_validation_records` (from a second terminal) lists a DNS record for ACM to validate `cluster_domain`. Add it, DNS only; the apply continues once it resolves.
2. Point `cluster_domain` at `tofu output load_balancer_dns_name` with a CNAME.
3. Initialise Vault, once: `aws ssm start-session --target $(tofu output -raw vault_instance_id)`, then `sudo vault-init`. It prints a recovery key and a root token, shown only this once: keep both in a password manager. It stores the nodes' Vault token in SSM, and they pick it up within a minute. Until then a node runs, but environment config values (`Environment.setValue`, `Environment.Config.lookup`) fail.

Nodes and Vault have no SSH: reach them with `aws ssm start-session`.

### Using the cluster
The apply writes `outputs/cluster-config.u`, with a `ClientConfig` you can use to deploy services and run jobs against your cluster.

You can save this output into your scratch file, or load this file into a ucm session with `> load /path/to/outputs/cluster-config.u`, and then you should be able to `> run sampleJob`, which will attempt to launch a job on your cluster.

### Secrets

- The node token is made once, by `cluster.tf`, and goes straight into SSM Parameter Store (`/<cluster_name>/nimbus/cluster-token`); it is never in OpenTofu state or the launch template. Change `cluster_token_generation` to make a new one, then refresh the instances.
- Environment config values live in Vault, on its own encrypted volume, auto-unsealed through KMS.

### Logs

Each node's container logs go to the CloudWatch log group `/<cluster_name>/nodes`, one stream per instance, kept for `node_log_retention_days`. They outlive the instance. The driver is non-blocking, so a CloudWatch outage drops log lines rather than holding up a node.

`aws logs tail /<cluster_name>/nodes --since 1h --follow` reads them.

### Alerts

[alerts.tf](alerts.tf) emails `alert_email` when:

- spend passes `budget_warning_percent` of `monthly_budget_usd`, then all of it (the whole account's spend)
- healthy nodes stay below `unison_desired_instances` for ten minutes
- over 5% of requests answer 5xx for five minutes, once there are 20 requests a minute
- Vault's instance fails a status check, which also recovers or reboots it
- DynamoDB throttles requests or reports system errors

`alert_email` has no default, so an apply cannot quietly drop the alerts. In a public repository, set it in a file such as `alerts.auto.tfvars`, which git ignores and `tofu` reads on its own.

AWS sends a confirmation email for the subscription, and alarms stay silent until the link in it is clicked. Budget warnings need no confirmation.

To test the email, set an alarm's state by hand: `aws cloudwatch set-alarm-state --alarm-name <cluster_name>-server-errors --state-value ALARM --state-reason test`. It returns to OK at its next evaluation.

These all watch from inside AWS. Check the service from outside it too, with anything that can read a URL on a schedule and send an email.

### State

OpenTofu state is the only record of what this manages, and it is a local file by default. To keep it in S3 instead, encrypted and versioned, with a lock so two applies cannot overlap, once per account:

1. In [`state-backend`](state-backend): `tofu init`, then `tofu apply -var cluster_name=<cluster_name> -var aws_region=<region>`.
2. Add a backend to [main.tf](main.tf) in place of `local`, with the `bucket` it prints:

   ```hcl
   backend "s3" {
     bucket       = "<bucket>"
     key          = "ec2/terraform.tfstate"
     region       = "<region>"
     encrypt      = true
     use_lockfile = true
   }
   ```

3. `tofu init -migrate-state`. Every apply then writes to S3, and the bucket keeps earlier versions, so there is nothing to back up by hand.

## Tearing down the infrastructure

To tear down all the EC2 instances and associated resources, run:

```bash
$ tofu destroy
```

It stops before deleting data: the DynamoDB table has deletion protection, the S3 buckets refuse to be deleted while they hold objects, the load balancer has deletion protection, and Vault's data volume is `prevent_destroy`. Remove those deliberately if you mean to delete the cluster's data.


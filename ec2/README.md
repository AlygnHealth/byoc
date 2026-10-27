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

The nimbus image. The published `unisoncomputing/unison-cloud` images (the newest is from 2025-11-19) are refused by the current control plane (`key "hostname" not found`, [byoc#2](https://github.com/unisoncomputing/byoc/issues/2)). [`../nimbus-image`](../nimbus-image) builds a current one from the `@unison/nimbus` source; push it to a registry the nodes can pull from and name it here.

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

## Tearing down the infrastructure

To tear down all the EC2 instances and associated resources, run:

```bash
$ tofu destroy
```

It stops before deleting data: the DynamoDB table has deletion protection, the S3 buckets refuse to be deleted while they hold objects, the load balancer has deletion protection, and Vault's data volume is `prevent_destroy`. Remove those deliberately if you mean to delete the cluster's data.


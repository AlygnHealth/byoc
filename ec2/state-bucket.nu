#!/usr/bin/env nu
# Makes the S3 bucket that holds this directory's OpenTofu state: encrypted,
# versioned, closed to the public, TLS only, keeping a year of old versions.
# A plain script rather than a stack of its own, so the bucket adds no second
# state to keep: the backend has to exist before the state it holds, and this
# bucket is made once. Safe to run again; each step sets what it sets.
#
#   nu state-bucket.nu <cluster_name> <region>
#   nu state-bucket.nu <cluster_name> <region> --print   # show, run nothing

def bucket-steps [bucket: string, region: string] {
    let location = if $region == "us-east-1" { [] } else {
        ["--create-bucket-configuration" $"LocationConstraint=($region)"]
    }
    let encryption = {
        Rules: [{ApplyServerSideEncryptionByDefault: {SSEAlgorithm: "aws:kms"}, BucketKeyEnabled: true}]
    }
    let tls_only = {
        Version: "2012-10-17"
        Statement: [{
            Sid: "TlsOnly", Effect: "Deny", Principal: "*", Action: "s3:*"
            Resource: [$"arn:aws:s3:::($bucket)" $"arn:aws:s3:::($bucket)/*"]
            Condition: {Bool: {"aws:SecureTransport": "false"}}
        }]
    }
    # Every apply makes a version. A year of them is more than a rollback needs.
    let lifecycle = {
        Rules: [{
            ID: "old-versions", Status: "Enabled", Filter: {}
            NoncurrentVersionExpiration: {NoncurrentDays: 365, NewerNoncurrentVersions: 50}
        }]
    }
    [
        {what: "create", args: (["create-bucket" "--bucket" $bucket] ++ $location), unless_exists: true}
        {what: "close to the public", args: ["put-public-access-block" "--bucket" $bucket "--public-access-block-configuration" "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"]}
        {what: "version", args: ["put-bucket-versioning" "--bucket" $bucket "--versioning-configuration" "Status=Enabled"]}
        {what: "encrypt", args: ["put-bucket-encryption" "--bucket" $bucket "--server-side-encryption-configuration" ($encryption | to json --raw)]}
        {what: "TLS only", args: ["put-bucket-policy" "--bucket" $bucket "--policy" ($tls_only | to json --raw)]}
        {what: "expire old versions", args: ["put-bucket-lifecycle-configuration" "--bucket" $bucket "--lifecycle-configuration" ($lifecycle | to json --raw)]}
    ]
}

def exists [bucket: string, region: string] {
    (^aws s3api head-bucket --bucket $bucket --region $region | complete).exit_code == 0
}

def main [
    cluster_name: string  # the cluster's name, as in terraform.tfvars
    region: string        # where to keep it, normally the cluster's region
    --print               # print the AWS CLI calls and run nothing
] {
    let bucket = $"($cluster_name)-tofu-state"
    for step in (bucket-steps $bucket $region) {
        let call = (["aws" "s3api"] ++ $step.args ++ ["--region" $region])
        if $print {
            print ($call | str join " ")
        } else if ($step.unless_exists? | default false) and (exists $bucket $region) {
            print $"($bucket) exists"
        } else {
            print $"($step.what): ($bucket)"
            let result = (^$call.0 ...($call | skip 1) | complete)
            if $result.exit_code != 0 {
                error make {msg: $"($step.what) failed: ($result.stderr | str trim)"}
            }
        }
    }
    print $"bucket = \"($bucket)\""
}

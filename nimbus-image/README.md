# A current nimbus image

The newest published `unisoncomputing/unison-cloud` image (`cloud_nimbus_releases_42_10_0_24676`, 2025-11-19) cannot join today's control plane: the control plane requires a `hostname` field in a node's register message, which that build does not send ([byoc#2](https://github.com/unisoncomputing/byoc/issues/2)). The `@unison/nimbus` source on Unison Share does send it.

This builds an image from that source. It keeps the published image's wrapper scripts and packages, and replaces the compiled node and the UCM that runs it; see the [Dockerfile](Dockerfile).

## Build

With `ucm` 1.5.0, `gh`, `docker` and `nu`, and `@unison/nimbus/main` in your codebase (`clone` or `pull` it in UCM):

```sh
nu build.nu --tag ghcr.io/<you>/nimbus-share:<date>
```

`--skip-docker` stops before `docker build`.

## Check it

One node, against your cluster's token, with no storage behind it, should log `location registered` and a member list:

```sh
docker run --rm -e NIMBUS_CONFIG_DIR=/cfg -v <dir with nimbus-config.json and nimbus-secrets.json>:/cfg <image>
```

## Publish

The nodes pull it, so push it somewhere they can reach, such as GHCR (`docker login ghcr.io`, `docker push`, then make the package public, or give the nodes credentials) or ECR, and set `unison_cloud_image` and `unison_cloud_image_tag` in `ec2/terraform.tfvars`.

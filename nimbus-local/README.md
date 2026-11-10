# A nimbus node on this machine

One nimbus node and the services it needs, run as host processes, for trying a
nimbus change before building an image or rolling AWS. No Docker or Podman: the
node is `ucm run.compiled nodeMain.uc`, exactly what the image runs, and the
services come from nix.

| Port | What | Stand-in for |
| --- | --- | --- |
| 8080 | Caddy, with an access log | the address the `alygnhealth-local` cluster is registered at |
| 8081, 8082 | nimbus | |
| 8000 | DynamoDB local | DynamoDB |
| 8200 | OpenBao dev server | Vault |
| 9000 | versitygw | S3 (virtual-host buckets and an `ETag` on every put, which nimbus needs; `rclone serve s3` sends no `ETag`) |
| 4566 | `fake_cloudwatch.py` | CloudWatch Logs `FilterLogEvents` |

The node registers with Unison's control plane as `alygnhealth-local`, using the
token in `../docker/nimbus-secrets.json`, which is merged into the config and
never printed. Point a client at it with the host
`alygnhealth-local.byoc.unison.cloud`, for example
`run alygnhealth.byoc.logsDemo alygnhealth-local.byoc.unison.cloud`.

## Use

- [ ] `./start.sh` starts everything with the node in `../nimbus-image`
  (`NODE_UC=<file.uc> ./start.sh` for another).
- [ ] `./compile.sh @unison/nimbus/<branch> [scratch.u]` compiles `main.nodeMain`
  with a scratch applied, in a copy of the codebase, into `state/nodeMain.uc`;
  `./restart-node.sh state/nodeMain.uc` swaps the node in a few seconds.
- [ ] `./stop.sh` stops it all; `state/` stays for reading.

## What to read

- `state/nimbus.log`: the node's own output.
- `state/requests.jsonl`: every `FilterLogEvents` request nimbus made, with its
  filter pattern and window.
- `state/events.tsv`: the node's lines with the time they were written; the fake
  CloudWatch answers from these, every filter term matched as a substring.
- `state/access.log`: requests that came in through port 8080. API calls from
  the control plane do not come this way; to see those, compile a node that
  prints them (`http.handleIncomingPublicRequest`'s last case).

Port 8080 is also where a local AlygnApp deploy listens: stop this first.

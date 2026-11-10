#!/usr/bin/env bash
# One nimbus node and the services it needs, as host processes, for testing a
# nimbus change without building an image or touching AWS. See README.md.
#
#   ./start.sh                     # the node in ../nimbus-image (what the image runs)
#   NODE_UC=<file.uc> ./start.sh   # a node compiled elsewhere
#
# Everything it writes is under state/. Ports: 8080 (the node, as the cluster is
# registered), 8081/8082 (nimbus), 8000 (DynamoDB), 8200 (Vault), 9000 (S3),
# 4566 (CloudWatch Logs).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
L="$here/state"
IMAGE="$here/../nimbus-image"                    # nodeMain.uc and the UCM that compiled it
SECRETS="$here/../docker/nimbus-secrets.json"    # the local cluster's token; merged, never printed
NODE_UC=${NODE_UC:-$IMAGE/nodeMain.uc}
build() { NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths "nixpkgs#$1"; }
BAO=$(build openbao)/bin/bao                     # Vault's API, open source
DDB=$(build dynamodb-local)/bin/dynamodb-local
AWS=$(build awscli2)/bin/aws
VGW=$(build versitygw)/bin/versitygw             # S3; answers virtual-host buckets and sends ETags, as nimbus needs
CADDY=$(build caddy)/bin/caddy

mkdir -p "$L/s3/unison-cloud-services" "$L/s3/unison-cloud-user-blobs" "$L/run"
: > "$L/events.tsv"; : > "$L/requests.jsonl"
bg() { name=$1; shift; setsid nohup "$@" > "$L/$name.log" 2>&1 < /dev/null & echo $! > "$L/run/$name.pid"; }

bg vault "$BAO" server -dev -dev-root-token-id=INSECURE_DEV_TOKEN -dev-listen-address=127.0.0.1:8200
# DynamoDB local writes a metadata file where it starts, so it starts in state/.
bg dynamo bash -c "cd '$L' && exec '$DDB' -inMemory -port 8000"
bg s3 "$VGW" --port :9000 --access unison-cloud --secret INSECURE_DEV_TOKEN --virtual-domain localhost --region us-west-2 posix "$L/s3"
bg cloudwatch python3 -I "$here/fake_cloudwatch.py" serve "$L/events.tsv" 4566 "$L/requests.jsonl"

until curl -s http://127.0.0.1:8200/v1/sys/health > /dev/null; do sleep 1; done
BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=INSECURE_DEV_TOKEN "$BAO" secrets enable -path=unison-cloud-environments kv-v2 > /dev/null
until curl -s http://127.0.0.1:8000 > /dev/null; do sleep 1; done
AWS_ACCESS_KEY_ID=myAccessKey AWS_SECRET_ACCESS_KEY=mySecretKey AWS_REGION=us-west-2 "$AWS" --endpoint-url http://127.0.0.1:8000 \
  dynamodb create-table --table-name unison-cloud-storage \
  --attribute-definitions AttributeName=K,AttributeType=B AttributeName=NS,AttributeType=S \
  --key-schema AttributeName=K,KeyType=HASH AttributeName=NS,KeyType=RANGE \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 > /dev/null

cat > "$L/run/local.json" <<JSON
{
  "environment": "local",
  "host": "127.0.0.1",
  "clusterMap": {},
  "bindPorts": { "publicHttp": 8082, "gossipHttp": 8081 },
  "blobFetcher": { "bucket": "unison-cloud-services",
    "awsConfig": { "hostName": "localhost", "port": 9000, "https": false, "region": "us-west-2" } },
  "userBlobFetcher": { "bucket": "unison-cloud-user-blobs",
    "awsConfig": { "hostName": "localhost", "port": 9000, "https": false, "region": "us-west-2" } },
  "vault": { "host": "127.0.0.1", "port": 8200, "scheme": "http" },
  "environmentsMount": "unison-cloud-environments",
  "dynamo": { "host": "127.0.0.1", "port": 8000, "type": "local" },
  "logs": { "provider": { "type": "cloudwatch", "region": "us-west-2", "logGroup": "/local/nodes",
    "hostName": "127.0.0.1", "port": 4566, "https": false } },
  "meta": { "nimbusVersion": "$(cat "$IMAGE/version.txt")", "ucmVersion": "$("$IMAGE/unison" --version)" }
}
JSON
jq -s '.[0] * .[1]' "$SECRETS" "$L/run/local.json" > "$L/run/config-merged.json"
chmod 600 "$L/run/config-merged.json"

# The cluster is registered as served at http://localhost:8080, as the Compose setup's proxy did.
cat > "$L/run/Caddyfile" <<CADDY
{
  admin off
}
http://:8080 {
  log {
    output file $L/access.log
    format json
  }
  reverse_proxy 127.0.0.1:8082
}
CADDY
bg proxy "$CADDY" run --config "$L/run/Caddyfile" --adapter caddyfile

"$here/restart-node.sh" "$NODE_UC"

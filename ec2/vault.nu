#!/usr/bin/env nu
# Vault's servers, changed without a gap of minutes (AlygnApp issue #389).
#
# Normally one server runs. An update starts a second on the newest image,
# joins it to the first's Raft cluster, hands it the leadership and the address
# the nodes use, and removes the first. Until the first is removed, `abort`
# puts everything back on it.
#
#   nu vault.nu status        # the servers, the leader, who holds the address
#   nu vault.nu setup         # once: every step before the first update, resumable
#   nu vault.nu update        # a new server, the handover, the old one removed
#   nu vault.nu abort         # mid-update: back to the old server
#   nu vault.nu finish        # mid-update: keep the new server, remove the old
#   nu vault.nu self-test
#
# `setup` runs `migrate` (the first server from file storage to Raft) and
# `claim` (the nodes' address onto it) itself; both can also be run alone.
#
# Run from ec2/, with AWS credentials and `tofu init` done. Every step on a
# server goes through SSM Run Command; nothing secret is ever in a command:
# Vault commands read the operator token from SSM on the server itself.
# `docs/AwsCommands.md` in AlygnApp has the routine around it.

const SERVERS_FILE = "vault-servers.auto.tfvars.json"
# A new server's name and host number in the first private subnet, inside the
# block vault.tf reserves for Vault.
const SLOTS = [{name: "a", host: 97} {name: "b", host: 98}]
const VAULT_TARGETS = [
    "aws_ebs_volume.vault_data"
    "aws_instance.vault"
    "aws_volume_attachment.vault_data"
    "aws_cloudwatch_metric_alarm.vault_host"
    "aws_cloudwatch_metric_alarm.vault_instance"
]

# ---- pure parts, held by self-test

# The slot a new server takes: the first one no running server holds.
def next-slot [running: list<string>] {
    $SLOTS | where name not-in $running | first
}

# The servers file for these servers.
def servers-json [servers: record, claimed: bool] {
    {vault_servers: $servers, vault_address_claimed: $claimed} | to json --indent 2
}

# `vault operator raft list-peers -format=json`, as rows.
def parse-peers [answer: string] {
    $answer | from json | get data.config.servers
    | each {|server| {name: $server.node_id, address: $server.address, leader: $server.leader, voter: $server.voter} }
}

# In a two-server update, which is old: the one launched first.
def old-and-new [instances: list<record>] {
    let sorted = ($instances | sort-by launched)
    {old: ($sorted | first), new: ($sorted | last)}
}

# The vault.hcl of a server moved from file storage to Raft: the storage
# stanza swapped, and its own address for joining and for standbys.
def raft-config [file_config: string, name: string, ip: string] {
    let storage = $'storage "raft" {
  path    = "/vault/data/raft"
  node_id = "($name)"
}'
    let lines = ($file_config | lines)
    let start = ($lines | enumerate | where {|row| $row.item | str starts-with 'storage "file"' } | first | get index)
    let length = ($lines | skip $start | enumerate | where {|row| $row.item == "}" } | first | get index)
    let kept = ($lines | first $start) ++ [$storage] ++ ($lines | skip ($start + $length + 1))
    $kept
    | where {|line| not ($line | str starts-with "api_addr") and not ($line | str starts-with "cluster_addr") }
    | append [$'api_addr     = "http://($ip):8200"' $'cluster_addr = "http://($ip):8201"']
    | str join "\n"
}

# The script that moves a stopped server from file storage to Raft, on the
# server: the file configuration kept, the data copied with the image Vault
# runs, the Raft configuration written, Vault started again.
def migrate-script [name: string, ip: string, next: string] {
    $"set -euo pipefail
test -f /etc/vault/vault.hcl.file-storage || cp /etc/vault/vault.hcl /etc/vault/vault.hcl.file-storage
image=$\(docker inspect --format '{{.Config.Image}}' vault)
cat > /etc/vault/migrate.hcl <<'HCL'
storage_source \"file\" {
  path = \"/vault/data\"
}
storage_destination \"raft\" {
  path    = \"/vault/data/raft\"
  node_id = \"($name)\"
}
cluster_addr = \"http://($ip):8201\"
HCL
# Until the Raft configuration is written, a failure starts Vault again on
# the file storage it still has.
trap 'systemctl start vault' ERR
systemctl stop vault
mkdir -p /opt/vault/data/raft
# A copy cut off earlier left part of the Raft data; the file data is the source.
find /opt/vault/data/raft -mindepth 1 -delete
# The image runs Vault as its own user, which must own the new folder.
chown -R 100:1000 /opt/vault/data
docker run --rm --entrypoint vault -v /etc/vault:/vault/config:ro -v /opt/vault/data:/vault/data \"$image\" operator migrate -config=/vault/config/migrate.hcl
chown -R 100:1000 /opt/vault/data
trap - ERR
cat > /etc/vault/vault.hcl <<'HCL'
($next)
HCL
systemctl start vault"
}

# Installs `vault-operator-token` on a server (one started by `update` has it
# from cloud-init): it asks for the root token and stores a token that may only
# manage Raft and step down in SSM.
def operator-token-script [region: string, parameter: string] {
    $"set -euo pipefail
cat > /usr/local/bin/vault-operator-token <<'SCRIPT'
#!/bin/bash
set -euo pipefail
read -rsp 'Root token: ' VAULT_TOKEN; echo
export VAULT_TOKEN
printf '%s\\n' \\
  'path \"sys/storage/raft/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"] }' \\
  'path \"sys/step-down\"      { capabilities = [\"update\", \"sudo\"] }' \\
  | docker exec -i -e VAULT_TOKEN vault vault policy write raft-operator -
docker exec -e VAULT_TOKEN vault vault token create -orphan -no-default-policy -policy=raft-operator -ttl=87600h -explicit-max-ttl=87600h -field=token \\
  | aws ssm put-parameter --region ($region) --name '($parameter)' --type SecureString --overwrite --value file:///dev/stdin > /dev/null
echo 'The operator token is stored.'
SCRIPT
chmod 0700 /usr/local/bin/vault-operator-token"
}

# Puts the address on, or takes it off, the interface that holds `own_ip`.
def address-script [own_ip: string, prefix: string, action: string] {
    $"set -euo pipefail
dev=$\(ip -o -4 addr show | awk '$4 ~ /^($own_ip)\\// {print $2}')
ip addr ($action) ($prefix) dev \"$dev\""
}

# ---- AWS, tofu and the servers

def outputs [] {
    ^tofu output -json | from json | transpose name value | reduce --fold {} {|row, acc| $acc | insert $row.name $row.value.value }
}

def read-servers [] { open $SERVERS_FILE }

def write-servers [servers: record, claimed: bool] {
    servers-json $servers $claimed | save --force $SERVERS_FILE
    print $"  ($SERVERS_FILE): (($servers | columns | str join ', '))"
}

def --wrapped aws-json [...args: string] {
    let answer = (^aws ...$args --output json | complete)
    if $answer.exit_code != 0 { error make {msg: $"aws ($args | first 2 | str join ' '): ($answer.stderr | str trim)"} }
    $answer.stdout | from json
}

# Each server's instance, with its own address and launch time.
def instances [] {
    let out = (outputs)
    $out.vault_instance_ids | transpose name id | each {|row|
        let described = (aws-json ec2 describe-instances --region $out.aws_region --instance-ids $row.id | get Reservations.0.Instances.0)
        {
            name: $row.name, id: $row.id, ip: ($out.vault_server_ips | get $row.name)
            launched: ($described.LaunchTime | into datetime)
            interface: ($described.NetworkInterfaces | where Attachment.DeviceIndex == 0 | first | get NetworkInterfaceId)
            volume: ($described.BlockDeviceMappings | where DeviceName == "/dev/sdf" | get -o 0.Ebs.VolumeId)
        }
    }
}

# Runs a shell script on an instance through SSM and answers its output;
# fails with its error output if it fails.
def remote [instance: string, script: string] {
    let region = ((outputs).aws_region)
    let parameters = ({commands: [$script]} | to json --raw)
    let command = (aws-json ssm send-command --region $region --instance-ids $instance --document-name AWS-RunShellScript --parameters $parameters | get Command.CommandId)
    mut status = "Pending"
    mut invocation = {}
    while $status in ["Pending" "InProgress" "Delayed"] {
        sleep 2sec
        let answer = (^aws ssm get-command-invocation --region $region --command-id $command --instance-id $instance --output json | complete)
        if $answer.exit_code == 0 {
            $invocation = ($answer.stdout | from json)
            $status = $invocation.Status
        }
    }
    if $status != "Success" {
        error make {msg: $"on ($instance): ($status): ($invocation.StandardErrorContent? | default '' | str trim)"}
    }
    $invocation.StandardOutputContent
}

# A Vault command on a server, with the operator token read there.
def vault-on [instance: string, command: string] {
    let out = (outputs)
    remote $instance $"set -euo pipefail
token=$\(aws ssm get-parameter --region ($out.aws_region) --with-decryption --name '($out.vault_operator_token_parameter)' --query Parameter.Value --output text)
docker exec -e VAULT_TOKEN=\"$token\" vault vault ($command)"
}

def peers-on [instance: string] { parse-peers (vault-on $instance "operator raft list-peers -format=json") }

def leader-on [instance: string] {
    let leaders = (peers-on $instance | where leader)
    if ($leaders | is-empty) { null } else { $leaders | first | get name }
}

def vault-status [instance: string] {
    # `vault status` exits 2 while sealed, which is an answer, not a failure.
    remote $instance "docker exec vault vault status -format=json || true" | from json
}

# Waits until `ready` answers true, up to `seconds`, saying what it waits for.
def wait-until [what: string, seconds: int, ready: closure] {
    print -n $"  waiting for ($what)"
    let deadline = ((date now) + ($seconds * 1sec))
    mut done = false
    while not $done {
        $done = (try { do $ready } catch { false })
        if not $done {
            if (date now) > $deadline { print ""; error make {msg: $"gave up waiting for ($what) after ($seconds) seconds"} }
            print -n "."
            sleep 3sec
        }
    }
    print " done"
}

# The instance holding the nodes' address, if any.
def address-holder [] {
    let out = (outputs)
    let found = (aws-json ec2 describe-network-interfaces --region $out.aws_region --filters $"Name=addresses.private-ip-address,Values=($out.vault_address)" | get NetworkInterfaces)
    if ($found | is-empty) { null } else { $found | first | get Attachment.InstanceId }
}

# Moves the nodes' address to `to`: AWS first, in one call that takes it from
# whoever has it, then the operating systems.
def move-address [to: record, from?: record] {
    let out = (outputs)
    let prefix = ($out.vault_address + "/25")
    print $"  moving ($out.vault_address) to ($to.name)"
    ^aws ec2 assign-private-ip-addresses --region $out.aws_region --network-interface-id $to.interface --private-ip-addresses $out.vault_address --allow-reassignment
    remote $to.id (address-script $to.ip $prefix "replace") | ignore
    if $from != null {
        try { remote $from.id (address-script $from.ip $prefix "del") | ignore }
    }
}

# Vault's health through the nodes' address, asked from `on`: 200 is the
# leader answering.
def health-through-address [on: string] {
    let out = (outputs)
    remote $on $"curl -s -o /dev/null -w '%{http_code}' http://($out.vault_address):8200/v1/sys/health" | str trim | into int
}

# The services' health addresses (`vault_update_checks`), each as passing or
# not, with what it answered.
def service-checks [] {
    (outputs).vault_update_checks | each {|url|
        let answer = (try { http get --full --allow-errors --max-time 15sec $url } catch {|failure| {status: 0, body: $failure.msg} })
        let body = $answer.body
        let ok = ($answer.status == 200 and ($body | describe | str starts-with "record") and ($body.status? == "ok"))
        let shown = (if ($body | describe | str starts-with "record") { $body | to json --raw } else { $body | to text })
        {url: $url, ok: $ok, answered: $"($answer.status) ($shown | str substring 0..80)"}
    }
}

def services-pass [] { service-checks | all {|check| $check.ok } }

def show-checks [] {
    service-checks | each {|check| print $"  (if $check.ok { 'ok  ' } else { 'FAIL' }) ($check.url)  ($check.answered)" } | ignore
}

def snapshot [server: record, why: string] {
    let region = ((outputs).aws_region)
    let made = (aws-json ec2 create-snapshot --region $region --volume-id $server.volume --description $"Vault ($server.name), ($why)" --tag-specifications $"ResourceType=snapshot,Tags=[{Key=Name,Value=vault-($server.name)-($why)}]")
    print $"  snapshot ($made.SnapshotId) of ($server.name)'s volume"
}

# A tofu apply of Vault's resources alone, on the terminal, so the plan is read
# and approved by a person. Anything else pending waits for a plain apply.
def apply-vault [] {
    let targets = ($VAULT_TARGETS | each {|target| $"-target=($target)" })
    try { ^tofu apply ...$targets } catch { error make {msg: "tofu apply did not apply"} }
}

def one-server [] {
    let running = (instances)
    if ($running | length) != 1 { error make {msg: $"expected one Vault server, found (($running | get name | str join ', ')); finish or abort the update first"} }
    $running | first
}

def two-servers [] {
    let running = (instances)
    if ($running | length) != 2 { error make {msg: "no update in progress: there is one Vault server"} }
    old-and-new $running
}

# ---- commands

def "main status" [] {
    let running = (instances)
    let holder = (address-holder)
    let leader = (try { leader-on ($running | first | get id) } catch { "unknown (no operator token yet, or no Raft)" })
    $running | each {|server|
        let state = (try { vault-status $server.id } catch { {} })
        {
            server: $server.name, instance: $server.id, ip: $server.ip, launched: $server.launched
            storage: ($state.storage_type? | default "?"), sealed: ($state.sealed? | default "?")
            leader: ($leader == $server.name), "holds address": ($holder == $server.id)
        }
    } | print
    if $holder == null { print "The nodes' address is not claimed yet: `nu vault.nu claim`." }
}

# Once: the first server's data from file storage to Raft, in place. Vault is
# down for under a minute. The file data stays beside the Raft data, and
# `migrate --undo` puts the file configuration back.
def "main migrate" [--undo] {
    let server = (one-server)
    if $undo {
        remote $server.id "set -euo pipefail
test -f /etc/vault/vault.hcl.file-storage
cp /etc/vault/vault.hcl.file-storage /etc/vault/vault.hcl
systemctl restart vault" | ignore
        wait-until "Vault on file storage again" 120 {|| (vault-status $server.id).storage_type == "file" and not (vault-status $server.id).sealed }
        return
    }
    let state = (vault-status $server.id)
    if $state.storage_type == "raft" { print $"($server.name) is on Raft already."; return }
    snapshot $server "before-raft"
    let current = (remote $server.id "cat /etc/vault/vault.hcl")
    let next = (raft-config $current $server.name $server.ip)
    print $"  migrating ($server.name): Vault stops until the copy is done"
    remote $server.id (migrate-script $server.name $server.ip $next) | print
    wait-until "Vault on Raft, unsealed" 180 {|| let now = (vault-status $server.id); $now.storage_type == "raft" and not $now.sealed }
    print $"($server.name) runs on Raft. If anything reads wrong: `nu vault.nu migrate --undo`."
}

# Once, after `migrate` and the operator token: the nodes' address onto the
# leader, then the servers file says so; the next `tofu apply` rolls the nodes
# onto it.
def "main claim" [] {
    let server = (one-server)
    if (leader-on $server.id) != $server.name { error make {msg: $"($server.name) does not lead its cluster"} }
    move-address $server
    wait-until "the address to answer" 60 {|| (health-through-address $server.id) == 200 }
    write-servers ((read-servers).vault_servers) true
    print "Now `tofu apply`: it points the nodes at the address and rolls them, one at a time."
}

# Back to the old server, from wherever an update stopped before the old
# server was removed.
def "main abort" [] {
    let pair = (two-servers)
    let old = $pair.old
    let new = $pair.new
    print $"Going back to ($old.name), removing ($new.name)."
    if (try { leader-on $old.id } catch { null }) == $new.name {
        vault-on $new.id "operator step-down" | ignore
        wait-until $"($old.name) to lead" 90 {|| (leader-on $old.id) == $old.name }
    }
    if (address-holder) == $new.id { move-address $old $new }
    if ((peers-on $old.id) | where name == $new.name | is-not-empty) {
        vault-on $old.id $"operator raft remove-peer ($new.name)" | ignore
    }
    let servers = ((read-servers).vault_servers | reject $new.name)
    write-servers $servers true
    apply-vault
    print $"Back on ($old.name) alone."
}

# Keeps the new server: the old one leaves the cluster, and tofu removes it
# and its volume.
def "main finish" [] {
    let pair = (two-servers)
    let old = $pair.old
    let new = $pair.new
    if (leader-on $new.id) != $new.name { error make {msg: $"($new.name) does not lead; `nu vault.nu abort` goes back to ($old.name)"} }
    if (address-holder) != $new.id { error make {msg: $"($new.name) does not hold the address; `nu vault.nu abort` goes back to ($old.name)"} }
    if ((peers-on $new.id) | where name == $old.name | is-not-empty) {
        vault-on $new.id $"operator raft remove-peer ($old.name)" | ignore
    }
    let servers = ((read-servers).vault_servers | reject $old.name)
    write-servers $servers true
    apply-vault
    print $"($new.name) is Vault's server now."
}

# The update: a new server on the current image and cloud-init, joined,
# handed the leadership and the address; then a check by a person, and the
# old server removed. A failure before that check goes back to the old server.
def "main update" [] {
    let old = (one-server)
    if (read-servers).vault_address_claimed != true { error make {msg: "setup is not finished: `nu vault.nu setup`"} }
    if (leader-on $old.id) != $old.name { error make {msg: $"($old.name) does not lead its cluster"} }
    if (address-holder) != $old.id { error make {msg: $"($old.name) does not hold the nodes' address"} }
    print "The services, before anything changes:"
    show-checks
    if not (services-pass) { error make {msg: "a service fails already, so a failure after the handover could not be told apart; nothing changed"} }
    print "1/5 snapshot of the current server's disk"
    snapshot $old "before-update"
    let slot = (next-slot [$old.name])
    print $"2/5 starting ($slot.name) beside ($old.name). Approve the plan: it adds ($slot.name)'s instance, volume and alarms."
    write-servers ((read-servers).vault_servers | insert $slot.name {host: $slot.host}) true
    try { apply-vault } catch {|failure|
        write-servers ((read-servers).vault_servers | reject $slot.name) true
        error make {msg: $"nothing changed: ($failure.msg)"}
    }
    try {
        let new = ((two-servers).new)
        wait-until $"($new.name) to boot and run Vault" 900 {|| (vault-status $new.id).initialized? != null }
        print $"3/5 joining ($new.name) to ($old.name)"
        remote $new.id $"docker exec vault vault operator raft join http://($old.ip):8200" | ignore
        wait-until $"($new.name) to unseal" 180 {|| not (vault-status $new.id).sealed }
        wait-until $"($new.name) to become a voter" 180 {|| (peers-on $old.id) | where {|peer| $peer.name == $new.name and $peer.voter } | is-not-empty }
        print $"4/5 handing the leadership and the address to ($new.name)"
        vault-on $old.id "operator step-down" | ignore
        wait-until $"($new.name) to lead" 90 {|| (leader-on $new.id) == $new.name }
        move-address $new $old
        wait-until "the address to answer from the new leader" 60 {|| (health-through-address $new.id) == 200 }
        print "5/5 checking the services"
        try { wait-until "every service to answer ok" 120 {|| services-pass } } catch {
            show-checks
            error make {msg: "a service fails after the handover"}
        }
        show-checks
    } catch {|failure|
        print $"Update stopped: ($failure.msg)"
        main abort
        error make {msg: "update aborted; the old server serves"}
    }
    let new = ((two-servers).new)
    print $"($new.name) leads and holds the address, and every service answers ok; ($old.name) still has every write."
    print "Anything else worth a look goes here (a page that reads a secret, say); after this, the snapshot is the way back."
    mut answer = ""
    while $answer not-in ["y" "n"] {
        $answer = (input $"Remove ($old.name) \(y\), or go back to it \(n\)? " | str trim | str substring 0..0 | str replace "Y" "y" | str replace "N" "n")
    }
    if $answer == "y" { main finish } else { main abort }
}

def ask [question: string] { (input $"($question) [y/N] " | str trim) in ["y" "Y" "yes" "Yes" "YES"] }

# Every step before the first update, in order. Each run finds the first step
# not yet done and starts there, so it is safe to run again after a stop.
def "main setup" [] {
    print "1/5 reserve Vault's addresses, and move the server into vault_servers"
    # Done when nothing is left to apply, so an apply cut off by an error is
    # finished on the next run. The block is checked only before it is reserved.
    let pending = (^tofu plan -input=false -detailed-exitcode | complete)
    if $pending.exit_code == 1 { error make {msg: $"tofu plan failed: ($pending.stderr | str trim)"} }
    if $pending.exit_code == 0 { print "  done" } else if "vault_address" in ((outputs) | columns) {
        print "  The block is reserved; the plan still has changes, from an apply that stopped or from something else pending."
        if not (ask "  Run `tofu apply` now?") { return }
        try { ^tofu apply } catch { error make {msg: "tofu apply did not apply; run setup again once it has"} }
    } else {
        let region = (^aws configure get region | str trim)
        let block = (seq 96 111 | each {|host| $"10.0.30.($host)" } | str join ",")
        let taken = (aws-json ec2 describe-network-interfaces --region $region --filters $"Name=addresses.private-ip-address,Values=($block)" | get NetworkInterfaces)
        if ($taken | is-not-empty) {
            error make {msg: $"something holds an address in 10.0.30.96/28, which Vault reserves: ($taken | get PrivateIpAddress | str join ', ')"}
        }
        print "  The plan should replace only the two Vault alarms; it reserves the block, adds the snapshots and gateway endpoints, and leaves the nodes and Vault alone."
        if not (ask "  Run `tofu apply` now?") { return }
        try { ^tofu apply } catch { error make {msg: "tofu apply did not apply; run setup again once it has"} }
    }

    let server = (one-server)
    print "2/5 move Vault from file storage to Raft"
    if (vault-status $server.id).storage_type == "raft" { print "  done" } else {
        if not (ask $"  Vault on ($server.name) stops for under a minute, so every service answers 500 meanwhile. Go?") { return }
        main migrate
    }

    let out = (outputs)
    print "3/5 the operator token"
    let has_token = {|| aws-json ssm describe-parameters --region $out.aws_region --parameter-filters $"Key=Name,Values=($out.vault_operator_token_parameter)" | get Parameters | is-not-empty }
    if (do $has_token) { print "  done" } else {
        # The root token is typed into a session on the server and goes nowhere
        # else: a command sent through SSM would keep it in the command's record.
        remote $server.id (operator-token-script $out.aws_region $out.vault_operator_token_parameter) | ignore
        print "  A session on the server opens here and asks for the root token from the password manager (typed, never echoed)."
        # Run attached to this terminal, so nothing of it is captured.
        try { ^aws ssm start-session --region $out.aws_region --target $server.id --document-name AWS-StartInteractiveCommand --parameters '{"command":["sudo /usr/local/bin/vault-operator-token"]}' } catch { print "  The session ended with an error." }
        if not (do $has_token) {
            print $"  The session did not store it. By hand, in another terminal:
    aws ssm start-session --target ($server.id)
    sudo vault-operator-token"
            input "  Press Enter once it is stored. "
        }
        if not (do $has_token) { error make {msg: $"($out.vault_operator_token_parameter) is still missing; run setup again once it is stored"} }
        if (leader-on $server.id) != $server.name { error make {msg: "the operator token does not read the cluster; check it was made on this server"} }
        print "  done"
    }

    print "4/5 put the nodes' address on the server"
    if (read-servers).vault_address_claimed and (address-holder) == $server.id { print "  done" } else { main claim }

    print "5/5 point the nodes at the address"
    let pending = (^tofu plan -input=false -detailed-exitcode -target=aws_launch_template.unison | complete)
    if $pending.exit_code == 0 { print "  done" } else {
        print "  The plan should change the nodes' launch template and roll them one at a time; Vault answers on both addresses meanwhile."
        if not (ask "  Run `tofu apply` now?") { return }
        try { ^tofu apply } catch { error make {msg: "tofu apply did not apply; run setup again once it has"} }
    }
    print "Setup is done. From now on an update is `nu vault.nu update`."
}

def "main self-test" [] {
    use std/assert
    assert equal (next-slot ["blue"]).name "a"
    assert equal (next-slot ["a"]).name "b"
    assert equal (next-slot ["b"]).name "a"
    assert equal (next-slot ["b"]).host 97
    let written = (servers-json {a: {host: 97}} true | from json)
    assert equal $written.vault_servers.a.host 97
    assert equal $written.vault_address_claimed true
    let peers = (parse-peers '{"data":{"config":{"servers":[{"node_id":"a","address":"10.0.30.97:8201","leader":true,"voter":true},{"node_id":"b","address":"10.0.30.98:8201","leader":false,"voter":false}]}}}')
    assert equal ($peers | where leader | get name) ["a"]
    assert equal ($peers | where not voter | get name) ["b"]
    let pair = (old-and-new [{name: "b", launched: (2026-11-11T10:00:00Z | into datetime)} {name: "a", launched: (2026-10-01T10:00:00Z | into datetime)}])
    assert equal [$pair.old.name $pair.new.name] ["a" "b"]
    let file_config = 'ui            = false
disable_mlock = true

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

seal "awskms" {
  region     = "us-west-2"
  kms_key_id = "abc"
}

api_addr = "http://127.0.0.1:8200"

max_lease_ttl = "87600h"'
    let raft = (raft-config $file_config "blue" "10.0.30.10")
    assert ($raft | str contains 'storage "raft" {')
    assert ($raft | str contains 'node_id = "blue"')
    assert not ($raft | str contains 'storage "file"')
    assert not ($raft | str contains '127.0.0.1')
    assert ($raft | str contains 'api_addr     = "http://10.0.30.10:8200"')
    assert ($raft | str contains 'cluster_addr = "http://10.0.30.10:8201"')
    assert ($raft | str contains 'kms_key_id = "abc"')
    assert ($raft | str contains 'max_lease_ttl')
    let migrate = (migrate-script "blue" "10.0.30.10" $raft)
    assert ($migrate | str contains 'node_id = "blue"')
    assert ($migrate | str contains 'cluster_addr = "http://10.0.30.10:8201"')
    assert ((^bash -n -c $migrate | complete).exit_code == 0) "the migrate script parses"
    let token_script = (operator-token-script "us-west-2" "/c/vault/operator-token")
    assert ((^bash -n -c $token_script | complete).exit_code == 0) "the operator token script parses"
    assert ($token_script | str contains "printf '%s\\n' \\\n") "its printf keeps the newline escape and the continuation"
    let add = (address-script "10.0.30.97" "10.0.30.100/25" "replace")
    assert ($add | str contains "/^10.0.30.97\\//")
    assert ($add | str contains 'ip addr replace 10.0.30.100/25 dev "$dev"')
    assert ((^bash -n -c $add | complete).exit_code == 0) "the address script parses"
    print "vault.nu self-test: ok"
}

def main [] { help main }

#!/usr/bin/env nu
# Builds a nimbus image from the @unison/nimbus source in the local codebase.
# See Dockerfile for why. Needs ucm (the same version as UCM_VERSION), gh and
# docker; @unison/nimbus/main must already be in the codebase (`clone` or
# `pull` it in UCM first).
#
#   nu build.nu                # compile, fetch UCM, docker build
#   nu build.nu --skip-docker  # everything but the docker build
#   nu build.nu --tag <name>   # image name (default nimbus-share:<date>)

const UCM_VERSION = "1.5.0"
const UCM_ASSET = "ucm-linux-x64.tar.gz"
const NIMBUS_BRANCH = "@unison/nimbus/main"

def main [--skip-docker, --tag: string] {
  let here = $env.FILE_PWD
  let work = $here | path join "work"
  mkdir $work

  let ucm_version = (^ucm version | str trim)
  if not ($ucm_version | str contains $"release/($UCM_VERSION)") {
    error make {msg: $"ucm is ($ucm_version); this build expects release/($UCM_VERSION), the UCM baked into the image"}
  }

  print $"Compiling main.nodeMain from ($NIMBUS_BRANCH)..."
  let uc_base = $work | path join "nodeMain"
  let transcript = $work | path join "compile.md"
  let compile_lines = [
    "```ucm"
    $"($NIMBUS_BRANCH)> compile main.nodeMain ($uc_base)"
    "```"
  ]
  $compile_lines | str join "\n" | save --force $transcript
  ^ucm --codebase $env.HOME transcript.fork $transcript
  cp ($uc_base + ".uc") ($here | path join "nodeMain.uc")

  print $"Fetching UCM ($UCM_VERSION)..."
  let tarball = $work | path join $UCM_ASSET
  if not ($tarball | path exists) {
    ^gh release download $"release/($UCM_VERSION)" -R unisonweb/unison -p $UCM_ASSET -D $work
  }
  let unpacked = $work | path join "ucm"
  mkdir $unpacked
  ^tar -xzf $tarball -C $unpacked
  cp ($unpacked | path join "unison" "unison") ($here | path join "unison")

  let date = (date now | format date "%Y-%m-%d")
  $"share-main-($date) ucm-($UCM_VERSION)\n" | save --force ($here | path join "version.txt")

  let image = $tag | default $"nimbus-share:($date)"
  if $skip_docker {
    print $"Ready to build: docker build -t ($image) ($here)"
  } else {
    ^docker build -t $image $here
    print $"Built ($image)"
  }
}

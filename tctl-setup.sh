#!/usr/bin/env bash
#
# Installs tctl cli tool and primes Docker Repo

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

source "${script_dir}/setenv.sh"

set -u

# Install and Prep TSB CLI and Registry

curl -Lo "${HOME}/bin/tctl" "https://binaries.dl.tetrate.io/public/raw/versions/darwin-amd64-${TSB_VERSION}/tctl"
chmod +x "${HOME}/bin/tctl"

tctl install image-sync \
  --username "${BINTRAY_USER}" \
  --apikey "${BINTRAY_APIKEY}" \
  --registry "${DOCKER_REGISTRY}"

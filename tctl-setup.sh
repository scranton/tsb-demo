#!/usr/bin/env bash
#
# Installs tctl cli tool and primes Docker Repo

# Get directory this script is located in to access script local files
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "${SCRIPT_DIR}/setenv.sh"

set -u

# Install and Prep TSB CLI and Registry

curl -Lo "${HOME}/bin/tctl" "https://tetrate.bintray.com/getcli/${TSB_VERSION}/darwin/amd64/tctl"
chmod +x "${HOME}/bin/tctl"

tctl install image-sync \
  --username "${BINTRAY_USER}" \
  --apikey "${BINTRAY_APIKEY}" \
  --registry "${DOCKER_REGISTRY}"

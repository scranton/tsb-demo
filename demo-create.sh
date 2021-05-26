#!/usr/bin/env bash
#
# Configure TSB demo

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

# Load shared Environment Variables
source "${script_dir}/setenv.sh"

# Load shared functions
source "${script_dir}/helpers/common_scripts.bash"

set -u
trap print_trap_error ERR

print_info 'Creating K8S Resources...'
bash -c "${script_dir}/k8s-create.sh"

print_info 'Configuring TSB Management Cluster...'
bash -c "${script_dir}/tsb-mgmt-install.sh"

print_info 'Configuring TSB Application Clusters...'
bash -c "${script_dir}/tsb-app-install.sh"

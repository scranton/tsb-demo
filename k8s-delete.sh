#!/usr/bin/env bash
#
# Delete K8s resouces

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

source "${script_dir}/setenv.sh"

# Load shared functions
source "${script_dir}/helpers/common_scripts.bash"

set -u
trap print_trap_error ERR

k8s::delete_cluster "${MGMT_K8S_TYPE}" "${MGMT_K8S_CLUSTER_NAME}" "${MGMT_K8S_CLUSTER_ZONE}"
k8s::delete_cluster "${APP1_K8S_TYPE}" "${APP1_K8S_CLUSTER_NAME}" "${APP1_K8S_CLUSTER_ZONE}"
k8s::delete_cluster "${APP2_K8S_TYPE}" "${APP2_K8S_CLUSTER_NAME}" "${APP2_K8S_CLUSTER_ZONE}"

# Cleanup script generated files
rm -rf "${script_dir}/generated"

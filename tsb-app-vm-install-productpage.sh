#!/usr/bin/env bash
#
# Configure TSB APP VM

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

# Load shared Environment Variables
source "${script_dir}/setenv.sh"

# Load shared functions
source "${script_dir}/helpers/common_scripts.bash"

set -u
trap print_trap_error ERR

readonly gen_dir="${script_dir}/generated/app2-vm-productpage"
mkdir -p "${gen_dir}"

readonly k8s_type="${APP2_K8S_TYPE}"
readonly k8s_cluster_name="${APP2_K8S_CLUSTER_NAME}"
readonly k8s_cluster_zone="${APP2_K8S_CLUSTER_ZONE}"
readonly tsb_cluster_name="${APP2_TSB_CLUSTER_NAME}"

# Get APP cluster k8s context
k8s::set_context "${k8s_type}" "${k8s_cluster_name}" "${k8s_cluster_zone}"

kubectl patch ControlPlane "${tsb_cluster_name}" \
  --namespace='istio-system' \
  --patch='{"spec":{"meshExpansion":{}}}' \
  --type='merge'

readonly az_resource_group="${k8s_cluster_name}-group"

ssh_key=$(cat "${HOME}/.ssh/id_rsa.pub")
readonly ssh_key

cp "${script_dir}/templates/vm/cloud-init-productpage.yaml" "${gen_dir}/cloud-init.yaml"

yq eval --inplace \
  "((.users.[] | select(.name == \"istio-proxy\").ssh_authorized_keys) |= [\"${ssh_key}\"]" \
  "${gen_dir}/cloud-init.yaml"

readonly vm_name='vm-productpage'

vm_result=$(
  az vm create \
    --resource-group "${az_resource_group}" \
    --name "${vm_name}" \
    --image Canonical:UbuntuServer:18.04-LTS:latest \
    --admin-username azureuser \
    --generate-ssh-keys \
    --custom-data "${gen_dir}/cloud-init.yaml"
)
echo "${vm_result}"

public_ip=$(jq --raw-output '.publicIpAddress' <<<"${vm_result}")
private_ip=$(jq --raw-output '.privateIpAddress' <<<"${vm_result}")

az vm list-ip-addresses \
  --resource-group "${az_resource_group}" \
  --name "${vm_name}" \
  --output table

az vm open-port \
  --resource-group "${az_resource_group}" \
  --port 80 \
  --name "${vm_name}"

cp "${script_dir}/templates/vm/productpage-workloadentry.yaml" "${gen_dir}/"

yq eval --inplace \
  "((.metadata.annotations.\"sidecar-bootstrap.istio.io/proxy-instance-ip\") |= \"${private_ip}\")" \
  "${gen_dir}/productpage-workloadentry.yaml"
yq eval --inplace \
  "((.spec.address) |= \"${public_ip}\")" \
  "${gen_dir}/productpage-workloadentry.yaml"

kubectl apply --filename "${gen_dir}/productpage-workloadentry.yaml"

cp "${script_dir}/templates/vm/productpage-sidecar.yaml" "${gen_dir}/"

kubectl apply --filename "${gen_dir}/productpage-sidecar.yaml"

ssh-keyscan -H "${public_ip}" >> ~/.ssh/known_hosts
ssh-copy-id -f "istio-proxy@${public_ip}"

tctl x sidecar-bootstrap productpage-vm.bookinfo \
  --start-istio-proxy

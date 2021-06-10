#!/usr/bin/env bash

# Get directory this script is located in to access script local files
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly _script_dir

# Color Prompts
readonly NOCOLOR='\e[0m'
readonly RED='\e[31m'
readonly YELLOW='\e[33m'
readonly BLUE='\e[34m'

readonly BOLDRED="\e[1;${RED}"

function print_waiting() {
  printf "⏳ ${YELLOW}%s${NOCOLOR}\n" "$1"
}

function print_info() {
  printf "${BLUE}==> %s${NOCOLOR}\n" "$1"
}

function print_error() {
  printf "${BOLDRED}==> %s${NOCOLOR}\n" "$1" >&2
}

function print_trap_error() {
  read -r line file <<<"$(caller)"
  print_error "An error occurred in line ${line} of file ${file}"
  print_error "$(sed "${line}q;d" "${file}")"
}

function k8s::get_service_address() {
  local svc="$1"
  local ns="$2"
  local addr=""

  until [[ -n ${addr} ]]; do
    addr=$(kubectl get service "${svc}" --namespace="${ns}" --output=jsonpath="{.status.loadBalancer.ingress[0].ip}")
    if [[ -z "${addr}" ]]; then
      addr=$(kubectl get service "${svc}" --namespace="${ns}" --output=jsonpath="{.status.loadBalancer.ingress[0].hostname}")
    fi
    sleep 5s
  done
  echo "${addr}"
}

#######################################
# Sets current Kubernetes Context
# Globals:
#   GCP_PROJECT_ID
# Arguments:
#   type - valid values: gke, aks
#   cluster_name
#   region
# Outputs:
#######################################
function k8s::set_context() {
  local _k8s_cluster_type="$1"
  local _k8s_cluster_name="$2"
  local _k8s_cluster_zone="$3"

  case ${_k8s_cluster_type} in
    gke)
      gcloud container clusters get-credentials "${_k8s_cluster_name}" \
        --project="${GCP_PROJECT_ID}" \
        --zone="${_k8s_cluster_zone}"
      ;;

    aks)
      az aks get-credentials \
        --name "${_k8s_cluster_name}" \
        --resource-group "${_k8s_cluster_name}-group" \
        --overwrite-existing
      ;;
  esac
}

#######################################
# Delete GKE cluster
# Globals:
#   GCP_PROJECT_ID
# Arguments:
#   cluster_name
#   region
# Outputs:
#######################################
function k8s::delete_gke_cluster() {
  local name="$1"
  local zone="$2"
  local region

  # shellcheck disable=SC2001
  region=$(echo "${zone}" | sed 's/\(.*\)-.*/\1/')

  # Delete GKE Cluster
  gcloud beta container clusters delete "${name}" \
    --project="${GCP_PROJECT_ID}" \
    --zone="${zone}" \
    --quiet

  # Cleanup Persistent disk volumes
  disk_list=$(
    gcloud compute disks list \
      --project="${GCP_PROJECT_ID}" \
      --filter="name ~ ${name} zone:( ${zone} )" \
      --format='value(name)'
  )
  for i in ${disk_list}; do
    gcloud compute --project="${GCP_PROJECT_ID}" disks delete "$i" \
      --zone="${zone}" \
      --quiet
  done

  # Cleanup GCP network resources
  PROJECT="${GCP_PROJECT_ID}" REGION="${region}" GKE_CLUSTER_NAME="${name}" bash -c "${_script_dir}/delete-orphaned-kube-network-resources.sh"
}

#######################################
# Delete Kubernetes cluster
# Globals:
#   GCP_PROJECT_ID
# Arguments:
#   type - valid values: gke, aks
#   cluster_name
#   region
# Outputs:
#######################################
function k8s::delete_cluster() {
  local type="$1"
  local name="$2"
  local zone="$3"

  case "${type}" in
    gke)
      k8s::delete_gke_cluster "${name}" "${zone}"
      ;;

    aks)
      az aks delete \
        --resource-group "${name}-group" \
        --name "${name}" \
        --yes

      az group delete \
        --name "${name}-group" \
        --yes
      ;;
  esac
}

#######################################
# Create Kubernetes cluster
# Globals:
#   GCP_PROJECT_ID
# Arguments:
#   type - valid values: gke, aks
#   cluster_name
#   region
# Outputs:
#   0 if DNS is associated with IP; non-zero on error.
#######################################
function k8s::create_cluster() {
  local type=$1
  local cluster_name=$2
  local region=$3

  case $type in
    gke)
      gcloud beta container clusters create "${cluster_name}" \
        --project="${GCP_PROJECT_ID}" \
        --zone="${region}" \
        --no-enable-basic-auth \
        --release-channel='regular' \
        --machine-type='e2-standard-2' \
        --metadata='disable-legacy-endpoints=true' \
        --num-nodes=2 \
        --enable-ip-alias \
        --enable-autoscaling \
        --min-nodes=0 \
        --max-nodes=5 \
        --enable-network-policy \
        --no-issue-client-certificate \
        --no-enable-master-authorized-networks \
        --image-type='COS_CONTAINERD'
      ;;

    aks)
      local aks_resource_group="${cluster_name}-group"

      az group create \
        --name "${aks_resource_group}" \
        --location "${region}"

      az network vnet create \
        --resource-group "${aks_resource_group}" \
        --name "${cluster_name}-vnet" \
        --subnet-name default

      az aks create \
        --resource-group "${aks_resource_group}" \
        --name "${cluster_name}" \
        --network-plugin azure \
        --docker-bridge-address 172.17.0.1/16 \
        --dns-service-ip 10.2.0.10 \
        --service-cidr 10.2.0.0/24 \
        --node-count 2 \
        --node-vm-size 'Standard_D4s_v3' \
        --enable-addons 'monitoring' \
        --generate-ssh-keys \
        --enable-cluster-autoscaler \
        --min-count 1 \
        --max-count 5
      ;;
  esac
}

#######################################
# Updates Cloud DNS A record
# Globals:
#   GCP_DNS_PROJECT_ID
#   GCP_DNS_ZONE_ID
# Arguments:
#   type - valid values: gke, aks
#   cluster_name
#   region
# Outputs:
#   0 if DNS update succeeded; non-zero on error.
#######################################
function dns::update_cloud_dns_address() {
  local fqdn=$1
  local new_ip=$2
  local old_ip

  old_ip=$(nslookup "${fqdn}" | grep 'Address:' | tail -n1 | awk '{print $2}')

  printf "\nIP_OLD = %s\n" "${old_ip}"
  printf "IP_NEW = %s\n\n" "${new_ip}"

  # Cleanup tmp files from any previous (failed) update attempts
  rm -f "${_script_dir}/transaction.yaml"

  # ignore failed deletions so that we can continue processing
  # set +e
  gcloud beta dns record-sets transaction start \
    --project="${GCP_DNS_PROJECT_ID}" \
    --zone="${GCP_DNS_ZONE_ID}"
  gcloud beta dns record-sets transaction remove "${old_ip}" \
    --project="${GCP_DNS_PROJECT_ID}" \
    --zone="${GCP_DNS_ZONE_ID}" \
    --name="${fqdn}." \
    --ttl="300" \
    --type="A" \
    || true # Ignore errors
  gcloud beta dns record-sets transaction add "${new_ip}" \
    --project="${GCP_DNS_PROJECT_ID}" \
    --zone="${GCP_DNS_ZONE_ID}" \
    --name="${fqdn}." \
    --ttl="300" \
    --type="A"
  gcloud beta dns record-sets transaction execute \
    --project="${GCP_DNS_PROJECT_ID}" \
    --zone="${GCP_DNS_ZONE_ID}"
  # set -e
}

#######################################
# Waits till DNS name is associated with an IP
# Will timeout after 5minutes (5 * 60 tries * 1 sec wait = 300 secs)
# Arguments:
#   DNS_NAME
#   TARGET_IP
# Outputs:
#   0 if DNS is associated with IP; non-zero on error.
#######################################
function dns::waitDNS() {
  local dns_name="$1"
  local target_ip="$2"
  local dns_ip=""
  local counter=0

  until [[ "${dns_ip}" == "${target_ip}" ]] || [[ ${counter} -gt 300 ]]; do
    dns_ip=$(nslookup "${dns_name}" | awk '/^Address: / { print $2 }')
    if [[ "${dns_ip}" != "${target_ip}" ]]; then
      sleep 5s
    fi
    ((counter++))
  done
  if [[ "${dns_ip}" != "${target_ip}" ]]; then
    printf "${BOLDRED}ERROR: For DNS NAME '%s', expected IP '%s' and got '%s'${NOCOLOR}" "${dns_name}" "${target_ip}" "${dns_ip}"
    return 1
  fi
  return 0
}

function tsb::gen_cluster_config() {
  local cluster_name=$1
  local gen_dir=$2

  tctl install manifest cluster-operators \
    --registry "${DOCKER_REGISTRY}" \
    >"${gen_dir}/clusteroperators.yaml"

  tctl install manifest control-plane-secrets \
    --allow-defaults \
    --elastic-password='tsb-elastic-password' \
    --elastic-username='tsb' \
    --xcp-certs="$(tctl install cluster-certs --cluster="${cluster_name}")" \
    --cluster="${cluster_name}" \
    >"${gen_dir}/controlplane-secrets.yaml"
}

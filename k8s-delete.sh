#!/usr/bin/env bash
#
# Delete GKE resouces

# Get directory this script is located in to access script local files
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "${SCRIPT_DIR}/setenv.sh"

delete_gke_cluster() {
  local project="$1"
  local name="$2"
  local zone="$3"
  local region

  # shellcheck disable=SC2001
  region=$(echo "${zone}" | sed 's/\(.*\)-.*/\1/')

  # Delete GKE Cluster
  gcloud beta container clusters delete "${name}" \
    --project="${project}" \
    --zone="${zone}" \
    --quiet

  # Cleanup Persistent disk volumes
  disk_list=$(
    gcloud compute disks list \
      --project="${project}" \
      --filter="name ~ ${name} zone:( ${zone} )" \
      --format='value(name)'
  )
  for i in ${disk_list}; do
    gcloud compute --project="${project}" disks delete "$i" \
      --zone="${zone}" \
      --quiet
  done

  # Cleanup GCP network resources
  PROJECT="${project}" REGION="${region}" GKE_CLUSTER_NAME="${name}" bash -c "${SCRIPT_DIR}/helpers/delete-orphaned-kube-network-resources.sh"
}

set -u

# Get MGMT GKE cluster k8s context
# gcloud container clusters get-credentials "${MGMT_GKE_CLUSTER_NAME}" \
#   --project="${GCP_PROJECT_ID}" \
#   --zone="${MGMT_GKE_CLUSTER_ZONE}"

# bash -c "${SCRIPT_DIR}/helpers/revoke_cert.sh"

delete_gke_cluster "${GCP_PROJECT_ID}" "${MGMT_GKE_CLUSTER_NAME}" "${MGMT_GKE_CLUSTER_ZONE}"
delete_gke_cluster "${GCP_PROJECT_ID}" "${APP1_GKE_CLUSTER_NAME}" "${APP1_GKE_CLUSTER_ZONE}"
delete_gke_cluster "${GCP_PROJECT_ID}" "${APP2_GKE_CLUSTER_NAME}" "${APP2_GKE_CLUSTER_ZONE}"

az aks delete \
  --resource-group "${APP3_AKS_RESOURCE_GROUP}" \
  --name "${APP3_K8S_CLUSTER_NAME}" \
  --yes

az group delete \
  --name "${APP3_AKS_RESOURCE_GROUP}" \
  --yes

# Cleanup script generated files
rm -rf "${SCRIPT_DIR}/generated"

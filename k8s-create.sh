#!/usr/bin/env bash
#
# Create GKE Kubernetes Clusters for TSB Demo

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

source "${script_dir}/setenv.sh"

set -u

# GCP DNS

# gcloud services enable dns.googleapis.com

# if [[ $(gcloud beta dns managed-zones list | grep -c "${GCP_DNS_ZONE_ID}") -eq 0 ]]; then
#   gcloud beta dns managed-zones create "${GCP_DNS_BASE_NAME}" \
#     --project="${GCP_PROJECT_ID}" \
#     --description="TSB Demo Zone" \
#     --dns-name="${GCP_DNS_BASE_NAME}." \
#     --visibility="public" \
#     --dnssec-state="off"
# fi

# Enable Container Registry
# gcloud services enable containerregistry.googleapis.com
# gcloud auth configure-docker

# Enable Kubernetes
gcloud services enable container.googleapis.com \
  --project="${GCP_PROJECT_ID}"

# Create MGMT GKE Cluster
(
gcloud beta container clusters create "${MGMT_GKE_CLUSTER_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --zone="${MGMT_GKE_CLUSTER_ZONE}" \
  --no-enable-basic-auth \
  --release-channel='regular' \
  --machine-type='e2-standard-2' \
  --metadata='disable-legacy-endpoints=true' \
  --num-nodes=3 \
  --enable-ip-alias \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=5 \
  --enable-network-policy \
  --no-issue-client-certificate \
  --no-enable-master-authorized-networks \
  --image-type='COS_CONTAINERD'
)&

# Create APP1 GKE Cluster
(
gcloud beta container clusters create "${APP1_GKE_CLUSTER_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --zone="${APP1_GKE_CLUSTER_ZONE}" \
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
)&

# Create APP2 GKE Cluster
(
gcloud beta container clusters create "${APP2_GKE_CLUSTER_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --zone="${APP2_GKE_CLUSTER_ZONE}" \
  --no-enable-basic-auth \
  --release-channel='regular' \
  --machine-type='e2-standard-4' \
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
)&

# Create APP3 AKS Cluster
(
az group create \
  --name "${APP3_AKS_RESOURCE_GROUP}" \
  --location "${APP3_AKS_REGION}"

az aks create \
  --resource-group "${APP3_AKS_RESOURCE_GROUP}" \
  --name "${APP3_K8S_CLUSTER_NAME}" \
  --node-count 2 \
  --node-vm-size 'Standard_D4_v3' \
  --enable-addons 'monitoring' \
  --generate-ssh-keys \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 5
)&

wait

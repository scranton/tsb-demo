#!/usr/bin/env bash
#
# Create GKE Kubernetes Clusters for TSB Demo

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

source "${script_dir}/setenv.sh"

set -u

readonly OS_GCP_PROJECT_ID='cxteam-scottcranton'

readonly gen_os_dir='generated/openshift'

mkdir -p "${gen_os_dir}"

gcloud config set project "${OS_GCP_PROJECT_ID}"

gcloud --project="${OS_GCP_PROJECT_ID}" services enable compute.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable cloudapis.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable cloudresourcemanager.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable dns.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable iamcredentials.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable iam.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable servicemanagement.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable serviceusage.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable storage-api.googleapis.com
gcloud --project="${OS_GCP_PROJECT_ID}" services enable storage-component.googleapis.com

gcloud iam service-accounts create sa-openshift \
    --description="OpenShift Service Account" \
    --display-name="OpenShift_SA"
gcloud projects add-iam-policy-binding "${OS_GCP_PROJECT_ID}" \
  --member="serviceAccount:sa-openshift@${OS_GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role='roles/owner'
gcloud iam service-accounts keys create "${gen_os_dir}/key.json" \
  --iam-account="sa-openshift@${OS_GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --key-file-type='json'

./openshift-install create cluster --dir=./generated/openshift

#!/usr/bin/env bash
#
# Environment variables used by all the scripts

export BINTRAY_USER='<TSB username>'
export BINTRAY_APIKEY='<TSB api key>'

export TSB_VERSION='1.3.0'

export GCP_PROJECT_ID='<GCP Project ID for GKE clusters>'

# export DOCKER_REGISTRY="containers.dl.tetrate.io"
export DOCKER_REGISTRY="gcr.io/${GCP_PROJECT_ID}"

export GCP_DNS_PROJECT_ID='<GCP Project id for CLoudDNS>'
export GCP_DNS_ZONE_ID='cranton-dev-zone'
export GCP_DNS_BASE_NAME='cranton.dev'

export TSB_DNS_EMAIL='<email for cert notifications>'

export BOOKINFO_DNS_SUFFIX='bookinfo.cranton.dev'
export TETRATE_DNS_SUFFIX='tetrate.cranton.dev'

export BOOKINFO_FQDN="${BOOKINFO_DNS_SUFFIX}"
export DETAILS_FQDN="details.${BOOKINFO_DNS_SUFFIX}"

# TSB Management Cluster on GKE us-east
export MGMT_TSB_CLUSTER_NAME='mgmt'
export MGMT_TSB_CLUSTER_REGION='us-east1'
export MGMT_TSB_FQDN="tsb.${TETRATE_DNS_SUFFIX}"
export MGMT_TSB_ADMIN_PASSWORD='<admin password>'
export MGMT_K8S_CLUSTER_NAME='tsb-demo-mgmt'
# export MGMT_K8S_TYPE='gke' # valid values: gke, aks
# export MGMT_K8S_CLUSTER_ZONE='us-east1-b'
export MGMT_K8S_TYPE='aks' # valid values: gke, aks
export MGMT_K8S_CLUSTER_ZONE='eastus'

# TSB Application Cluster 1 on GKE us-central
export APP1_TSB_CLUSTER_NAME='demo-app1'
export APP1_TSB_CLUSTER_REGION='us-central1'
export APP1_K8S_CLUSTER_NAME='tsb-demo-app1'
export APP1_K8S_TYPE='gke' # valid values: gke, aks
export APP1_K8S_CLUSTER_ZONE='us-central1-b'

# TSB Application Cluster 2 on AKS westus
export APP2_TSB_CLUSTER_NAME='demo-app2'
export APP2_TSB_CLUSTER_REGION='westus'
export APP2_K8S_CLUSTER_NAME='tsb-demo-app2'
export APP2_K8S_TYPE='aks' # valid values: gke, aks
export APP2_K8S_CLUSTER_ZONE='westus'
# export APP2_AKS_RESOURCE_GROUP='tsb-demo-scottcranton'

# export APP3_TSB_CLUSTER_NAME='demo-app3'
# export APP3_TSB_CLUSTER_REGION='eastus'
# export APP3_K8S_CLUSTER_NAME='tsb-demo-app3'
# export APP3_AKS_REGION='eastus'
# export APP3_AKS_RESOURCE_GROUP='tsb-demo-scottcranton'

export TSB_ORGANIZATION='tetrate'
export TSB_TENANT='tetrate'

# Absolute Paths
export CERTS_DIR='/Users/scranton/.certs'
export SECRETS_DIR='/Users/scranton/.secrets'
export ISTIO_CERTS_DIR='/Users/scranton/.getistio/istio/1.7.4-tetrate-v0/samples/certs'

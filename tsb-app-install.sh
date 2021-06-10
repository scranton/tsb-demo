#!/usr/bin/env bash
#
# Configure TSB APP Clusters

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

# Load shared Environment Variables
source "${script_dir}/setenv.sh"

# Load shared functions
source "${script_dir}/helpers/common_scripts.bash"

set -u
trap print_trap_error ERR

mkdir -p "${script_dir}/generated/app1"
mkdir -p "${script_dir}/generated/app2"
mkdir -p "${script_dir}/generated/app3"

# Install TSB Control Plane (aka Istio) into APP GKE Cluster

# Set Kubernetes Current Context to the GKE MGMT Cluster
k8s::set_context "${MGMT_K8S_TYPE}" "${MGMT_K8S_CLUSTER_NAME}" "${MGMT_K8S_CLUSTER_ZONE}"

# tctl login \
#   --org="${TSB_ORGANIZATION}" \
#   --tenant="${TSB_TENANT}" \
#   --username="admin" \
#   --password="${MGMT_TSB_ADMIN_PASSWORD}"

readonly gen_mgmt_dir="${script_dir}/generated/mgmt"
mkdir -p "${gen_mgmt_dir}"

# Configure TSB
cat <<EOF >"${gen_mgmt_dir}/tsb.yaml"
apiVersion: api.tsb.tetrate.io/v2
kind: Cluster
metadata:
  organization: ${TSB_ORGANIZATION}
  name: ${APP1_TSB_CLUSTER_NAME}
spec:
  tokenTtl: "8760h"
  locality:
    region: ${APP1_TSB_CLUSTER_REGION}
---
apiVersion: api.tsb.tetrate.io/v2
kind: Cluster
metadata:
  organization: ${TSB_ORGANIZATION}
  name: ${APP2_TSB_CLUSTER_NAME}
spec:
  tokenTtl: "8760h"
  locality:
    region: ${APP2_TSB_CLUSTER_REGION}
---
apiVersion: api.tsb.tetrate.io/v2
kind: Tenant
metadata:
  organization: ${TSB_ORGANIZATION}
  name: ${TSB_TENANT}
spec:
  displayName: ${TSB_TENANT}
---
apiversion: api.tsb.tetrate.io/v2
kind: Workspace
metadata:
  organization: ${TSB_ORGANIZATION}
  tenant: ${TSB_TENANT}
  name: bookinfo-ws
spec:
  namespaceSelector:
    names:
      - "*/bookinfo"
---
apiVersion: gateway.tsb.tetrate.io/v2
kind: Group
metadata:
  organization: ${TSB_ORGANIZATION}
  tenant: ${TSB_TENANT}
  workspace: bookinfo-ws
  name: bookinfo-gw-group
spec:
  configMode: BRIDGED
  namespaceSelector:
    names:
      - "*/bookinfo"
---
apiVersion: gateway.tsb.tetrate.io/v2
kind: Tier1Gateway
metadata:
  organization: ${TSB_ORGANIZATION}
  tenant: ${TSB_TENANT}
  workspace: bookinfo-ws
  group: bookinfo-gw-group
  name: bookinfo-tier1
spec:
  workloadSelector:
    namespace: bookinfo
    labels:
      app: tsb-gateway-bookinfo
  externalServers:
  - name: bookinfo
    hostname: ${BOOKINFO_FQDN}
    port: 443
    tls:
      mode: SIMPLE
      secretName: bookinfo-certs
    clusters:
    - name: ${APP1_TSB_CLUSTER_NAME}
      weight: 50
    - name: ${APP2_TSB_CLUSTER_NAME}
      weight: 50
---
apiVersion: gateway.tsb.tetrate.io/v2
kind: IngressGateway
metadata:
  organization: ${TSB_ORGANIZATION}
  tenant: ${TSB_TENANT}
  workspace: bookinfo-ws
  group: bookinfo-gw-group
  name: bookinfo-gw-ingress
  displayName: bookinfo-gw-ingress
spec:
  displayName: bookinfo-gw-ingress
  http:
  - name: bookinfo
    hostname: ${BOOKINFO_FQDN}
    port: 8443
    routing:
      rules:
      - route:
          host: bookinfo/productpage.bookinfo.svc.cluster.local
          port: 9080
    tls:
      mode: SIMPLE
      secretName: bookinfo-certs
  - name: details
    hostname: ${DETAILS_FQDN}
    port: 9080
    routing:
      rules:
      - route:
          host: bookinfo/details.bookinfo.svc.cluster.local
          port: 9080
    tls:
      mode: MUTUAL
      secretName: bookinfo-certs
  workloadSelector:
    labels:
      app: tsb-gateway-bookinfo
    namespace: bookinfo
EOF
tctl apply -f "${gen_mgmt_dir}/tsb.yaml"

# Get Bookinfo cert (secret) from Mgmt cluster to put into App clusters

readonly certs_dir="${script_dir}/generated/certs"
mkdir -p "${certs_dir}"

# TODO cleanup Bookinfo CERT sharing across cluster. look at cloud key managers
kubectl get secrets bookinfo-certs \
  --namespace='bookinfo' \
  --output='json' >"${certs_dir}/bookinfo-cert.json"
jq --raw-output '.data."tls.crt"' "${certs_dir}/bookinfo-cert.json" \
  | base64 --decode >"${certs_dir}/bookinfo.crt"
jq --raw-output '.data."tls.key"' "${certs_dir}/bookinfo-cert.json" \
  | base64 --decode >"${certs_dir}/bookinfo.key"

# Capture TSB Management Plane configuration details
mgmt_cp_json=$(
  kubectl get controlplane control-plane \
    --namespace='istio-system' \
    --output='json'
)
readonly mgmt_cp_json

function tsb::apply_cluster_config() {
  local tsb_cluster_name=$1
  local k8s_cluster_type=$2
  local k8s_cluster_name=$3
  local k8s_cluster_zone=$4
  local gen_dir=$5

  # Get APP cluster k8s context
  k8s::set_context "${k8s_cluster_type}" "${k8s_cluster_name}" "${k8s_cluster_zone}"

  # Copy Shared CA from getistio
  kubectl create namespace istio-system
  kubectl create secret generic cacerts \
    --namespace='istio-system' \
    --from-file="${ISTIO_CERTS_DIR}/ca-cert.pem" \
    --from-file="${ISTIO_CERTS_DIR}/ca-key.pem" \
    --from-file="${ISTIO_CERTS_DIR}/root-cert.pem" \
    --from-file="${ISTIO_CERTS_DIR}/cert-chain.pem"

  kubectl apply --filename="${gen_dir}/clusteroperators.yaml"

  print_waiting "Waiting for TSB ${tsb_cluster_name} ControlPlane to be deployed..."
  kubectl wait deployment/tsb-operator-control-plane \
    --namespace='istio-system' \
    --for='condition=Available' \
    --timeout='4m'

  # sleep 10s

  kubectl apply --filename="${gen_dir}/controlplane-secrets.yaml"

  sleep 30s

  kubectl apply --filename - <<EOF
apiVersion: install.tetrate.io/v1alpha1
kind: ControlPlane
metadata:
  name: ${tsb_cluster_name}
  namespace: istio-system
spec:
  hub: $(jq '.spec.hub' <<<"${mgmt_cp_json}")
  telemetryStore:
    elastic:
      host: $(jq --raw-output '.spec.telemetryStore.elastic.host' <<<"${mgmt_cp_json}")
      port: $(jq --raw-output '.spec.telemetryStore.elastic.port' <<<"${mgmt_cp_json}")
      version: $(jq --raw-output '.spec.telemetryStore.elastic.version' <<<"${mgmt_cp_json}")
  managementPlane:
    host: $(jq --raw-output '.spec.managementPlane.host' <<<"${mgmt_cp_json}")
    port: $(jq --raw-output '.spec.managementPlane.port' <<<"${mgmt_cp_json}")
    clusterName: ${tsb_cluster_name}
  meshExpansion: {}
EOF

  # Edge is last thing to start
  print_waiting 'Waiting for Istio control plane to be ready...'

  # Loop on `kubectl rollout status` as it takes a while for deployment/envoy to
  # exist and then to complete
  # kubectl rollout status --namespace='istio-system' deployment/edge
  attempts=0
  rollout_status_cmd='kubectl rollout status deployment/edge --namespace=istio-system'
  until ${rollout_status_cmd} || [[ ${attempts} -eq 60 ]]; do
    attempts=$((attempts + 1))
    sleep 10s
  done

  # Install Bookinfo Sample Application
  bash -c "${script_dir}/bookinfo-install.sh"

  # Create TSB Ingress Gateway
  kubectl --namespace='bookinfo' create secret tls 'bookinfo-certs' \
    --key="${certs_dir}/bookinfo.key" \
    --cert="${certs_dir}/bookinfo.crt"

  cp "${script_dir}/templates/tsb/ingress.yaml" "${gen_dir}"
  kubectl apply --filename="${gen_dir}/ingress.yaml"

  bookinfo_gateway_ip=$(k8s::get_service_address tsb-gateway-bookinfo bookinfo)

  printf '\nbookinfo_ingress_ip = %s\n\n' "${bookinfo_gateway_ip}"

  curl --silent --verbose "https://${BOOKINFO_FQDN}/productpage" \
    --resolve "${BOOKINFO_FQDN}:443:${bookinfo_gateway_ip}" \
    | grep --only-matching '<title>.*</title>'
}

tsb::gen_cluster_config "${APP1_TSB_CLUSTER_NAME}" "${script_dir}/generated/app1"
tsb::gen_cluster_config "${APP2_TSB_CLUSTER_NAME}" "${script_dir}/generated/app2"

tsb::apply_cluster_config "${APP1_TSB_CLUSTER_NAME}" "${APP1_K8S_TYPE}" "${APP1_K8S_CLUSTER_NAME}" "${APP1_K8S_CLUSTER_ZONE}" "${script_dir}/generated/app1"
tsb::apply_cluster_config "${APP2_TSB_CLUSTER_NAME}" "${APP2_K8S_TYPE}" "${APP2_K8S_CLUSTER_NAME}" "${APP2_K8S_CLUSTER_ZONE}" "${script_dir}/generated/app2"

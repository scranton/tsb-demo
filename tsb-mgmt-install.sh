#!/usr/bin/env bash
#
# Configure TSB demo
# see https://docs.tetrate.io/service-bridge/en-us/quickstart

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

# Load shared Environment Variables
source "${script_dir}/setenv.sh"

# Load shared functions
source "${script_dir}/helpers/common_scripts.bash"

set -u
trap print_trap_error ERR

# Install TSB into MGMT K8s Cluster

# Get MGMT cluster k8s context
k8s::set_context "${MGMT_K8S_TYPE}" "${MGMT_K8S_CLUSTER_NAME}" "${MGMT_K8S_CLUSTER_ZONE}"

# Create PostgresSQL database
print_info 'Creating Postgres DB...'

readonly aks_resource_group="${MGMT_K8S_CLUSTER_NAME}-group"

readonly postgres_username="tsb"
readonly postgres_password="TetrateFTW321"
# readonly postgres_password="tsb-postgres-password"
readonly postgres_db_server="${MGMT_K8S_CLUSTER_NAME}-db-server"
readonly postgres_db_name='tsb'
# fqdn_postgres='postgres'

az postgres server create \
  --location "${MGMT_K8S_CLUSTER_ZONE}" \
  --resource-group "${aks_resource_group}" \
  --name "${postgres_db_server}" \
  --admin-user "${postgres_username}" \
  --admin-password "${postgres_password}" \
  --version 11

postgress_server_create_result=$(
  az postgres server show \
    --resource-group "${aks_resource_group}" \
    --name "${postgres_db_server}"
)
printf "\nPostgres Server Create Result:\n%s\n\n" "${postgress_server_create_result}"

fqdn_postgres=$(jq --raw-output '.fullyQualifiedDomainName' <<<"${postgress_server_create_result}")
printf "\nPostgres FQDN %s" "${fqdn_postgres}"

az postgres server firewall-rule create \
  --resource-group "${aks_resource_group}" \
  --server-name "${postgres_db_server}" \
  --name AllowAll_2021-6-10_7-34-28 \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 255.255.255.255

az postgres db create \
  --resource-group "${aks_resource_group}" \
  --server-name "${postgres_db_server}" \
  --name "${postgres_db_name}"

# Install Cert-Manager
print_info 'Installing Cert Manager...'

# Known cert-manager issue with GKE may require elevated permissions
if [[ "${MGMT_K8S_TYPE}" == 'gke' ]]; then
  kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole='cluster-admin' \
    --user="$(gcloud config get-value core/account)" || true # ignore errors
fi

# Use helm to install cert-manager with DNS caching workaround
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade cert-manager jetstack/cert-manager \
  --namespace='cert-manager' \
  --install \
  --create-namespace \
  --version='v1.2.0' \
  --set 'installCRDs=true' \
  --set 'extraArgs={--dns01-recursive-nameservers-only=true,--dns01-recursive-nameservers=8.8.8.8:53\,1.1.1.1:53}' \
  --atomic

readonly gen_mgmt_dir="${script_dir}/generated/mgmt"

mkdir -p "${gen_mgmt_dir}"

# TSB Management Plane install
print_info 'Installing TSB...'

tctl install manifest management-plane-operator \
  --registry="${DOCKER_REGISTRY}" >"${gen_mgmt_dir}/mp-operator.yaml"
kubectl apply --filename="${gen_mgmt_dir}/mp-operator.yaml"

print_waiting 'Waiting for TSB Management Operator to be ready...'
kubectl wait deployment/tsb-operator-management-plane \
  --namespace='tsb' \
  --for='condition=Available' \
  --timeout='10m'

tctl install manifest management-plane-secrets \
  --elastic-password="tsb-elastic-password" \
  --elastic-username="tsb" \
  --ldap-bind-dn="cn=admin,dc=tetrate,dc=io" \
  --ldap-bind-password="admin" \
  --postgres-username="${postgres_username}@${postgres_db_server}" \
  --postgres-password="${postgres_password}" \
  --tsb-admin-password="${MGMT_TSB_ADMIN_PASSWORD}" \
  --tsb-server-certificate="aaa" \
  --tsb-server-key="bbb" \
  --xcp-certs >"${gen_mgmt_dir}/mp-secrets.yaml"
kubectl apply --filename="${gen_mgmt_dir}/mp-secrets.yaml"

# Configure TSB TLS Cert

# Assumes use of CertBot (helpers/gen-certs.sh)
readonly tetrate_certs_dir="${CERTS_DIR}/config/live/${TETRATE_DNS_SUFFIX}"

kubectl delete secret 'tsb-certs' \
  --namespace='tsb'
kubectl create secret tls 'tsb-certs' \
  --namespace='tsb' \
  --key="${tetrate_certs_dir}/privkey.pem" \
  --cert="${tetrate_certs_dir}/cert.pem"

print_info 'Deploying TSB Management Plane...'

sleep 60s

# cp "${script_dir}/templates/tsb/mp.yaml" "${gen_mgmt_dir}/"
# yq eval ".spec.hub |= \"${DOCKER_REGISTRY}\"" \
#   --inplace "${gen_mgmt_dir}/mp.yaml"
# kubectl apply --filename="${gen_mgmt_dir}/mp.yaml"
kubectl apply --filename - <<EOF
apiVersion: install.tetrate.io/v1alpha1
kind: ManagementPlane
metadata:
  name: managementplane
  namespace: tsb
spec:
  hub: ${DOCKER_REGISTRY}
  components:
    apiServer:
      teamSyncSchedule: 0 * * * *
    frontEnvoy:
      port: 443
  dataStore:
    postgres:
      address: "${fqdn_postgres}:5432"
      name: "${postgres_db_name}"
EOF

print_waiting 'Waiting for TSB Management Plane to be ready...'

# Loop on `kubectl rollout status` as it takes a while for deployment/envoy to
# exist and then to complete
attempts=0
rollout_status_cmd='kubectl rollout status deployment/envoy --namespace=tsb'
until ${rollout_status_cmd} || [[ ${attempts} -eq 60 ]]; do
  attempts=$((attempts + 1))
  sleep 10
done

kubectl create job teamsync-bootstrap \
  --namespace='tsb' \
  --from='cronjob/teamsync'

print_info 'Configuring DNS for TSB mgmt cluster...'

print_waiting 'Waiting for TSB IP...'
TSB_IP=$(k8s::get_service_address envoy tsb)

dns::update_cloud_dns_address "${MGMT_TSB_FQDN}" "${TSB_IP}"

print_waiting "Waiting for DNS ${MGMT_TSB_FQDN} to propogate..."
dns::waitDNS "${MGMT_TSB_FQDN}" "${TSB_IP}"

tctl config clusters set "${MGMT_TSB_CLUSTER_NAME}" \
  --bridge-address="${TSB_IP}:443"
tctl config users set "${MGMT_TSB_CLUSTER_NAME}-admin-user" \
  --org="${TSB_ORGANIZATION}" \
  --tenant="${TSB_TENANT}" \
  --username='admin' \
  --password="${MGMT_TSB_ADMIN_PASSWORD}"
tctl config profiles set "${MGMT_TSB_CLUSTER_NAME}" \
  --cluster="${MGMT_TSB_CLUSTER_NAME}" \
  --username="${MGMT_TSB_CLUSTER_NAME}-admin-user"
tctl config profiles set-current "${MGMT_TSB_CLUSTER_NAME}"

# tctl login \
#   --org="${TSB_ORGANIZATION}" \
#   --tenant="${TSB_TENANT}" \
#   --username='admin' \
#   --password="${MGMT_TSB_ADMIN_PASSWORD}"

print_info 'Installing Management Cluster Control Plane...'

sleep 30s

# Copy Shared CA from getistio
kubectl create namespace istio-system
kubectl create secret generic cacerts \
  --namespace='istio-system' \
  --from-file="${ISTIO_CERTS_DIR}/ca-cert.pem" \
  --from-file="${ISTIO_CERTS_DIR}/ca-key.pem" \
  --from-file="${ISTIO_CERTS_DIR}/root-cert.pem" \
  --from-file="${ISTIO_CERTS_DIR}/cert-chain.pem"

tctl apply --file - <<EOF
apiVersion: api.tsb.tetrate.io/v2
kind: Cluster
metadata:
  name: ${MGMT_TSB_CLUSTER_NAME}
  organization: ${TSB_ORGANIZATION}
spec:
  tokenTtl: "8760h"
  tier1Cluster: true
  locality:
    region: ${MGMT_TSB_CLUSTER_REGION}
EOF

tctl install manifest cluster-operator \
  --registry "${DOCKER_REGISTRY}" >"${gen_mgmt_dir}/cp-operator.yaml"
kubectl apply --filename="${gen_mgmt_dir}/cp-operator.yaml"

tctl install manifest control-plane-secrets \
  --xcp-certs "$(tctl install cluster-certs --cluster="${MGMT_TSB_CLUSTER_NAME}")" \
  --elastic-password="tsb-elastic-password" \
  --elastic-username="tsb" \
  --cluster="${MGMT_TSB_CLUSTER_NAME}" >"${gen_mgmt_dir}/cp-secrets.yaml"
kubectl apply --filename="${gen_mgmt_dir}/cp-secrets.yaml"

print_waiting 'Waiting for ControlPlane to be deployed...'
kubectl wait deployment/tsb-operator-control-plane \
  --namespace='istio-system' \
  --for='condition=Available' \
  --timeout='4m'

# TODO: wait for CRD ControlPlane.install.tetrate.io/v1alpha1
sleep 30s

cp "${script_dir}/templates/tsb/mgmt-cp.yaml" "${gen_mgmt_dir}/"
yq eval ".spec.hub |= \"${DOCKER_REGISTRY}\"" --inplace "${gen_mgmt_dir}/mgmt-cp.yaml"
yq eval ".spec.telemetryStore.elastic.host |= \"${MGMT_TSB_FQDN}\"" --inplace "${gen_mgmt_dir}/mgmt-cp.yaml"
yq eval ".spec.managementPlane.host |= \"${MGMT_TSB_FQDN}\"" --inplace "${gen_mgmt_dir}/mgmt-cp.yaml"
yq eval ".spec.managementPlane.clusterName |= \"${MGMT_TSB_CLUSTER_NAME}\"" --inplace "${gen_mgmt_dir}/mgmt-cp.yaml"
kubectl apply --filename="${gen_mgmt_dir}/mgmt-cp.yaml"

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

# Configure Tier1 Bookinfo Gateway

# Create Bookinfo TLS Cert

kubectl create namespace bookinfo
kubectl label namespace bookinfo 'istio-injection=enabled'

# Assumes use of CertBot (helpers/gen-certs.sh)
readonly bookinfo_certs_dir="${CERTS_DIR}/config/live/${BOOKINFO_DNS_SUFFIX}"

kubectl --namespace='bookinfo' create secret tls 'bookinfo-certs' \
  --key="${bookinfo_certs_dir}/privkey.pem" \
  --cert="${bookinfo_certs_dir}/cert.pem"

cp "${script_dir}/templates/tsb/ingress.yaml" "${gen_mgmt_dir}/"
kubectl apply --filename="${gen_mgmt_dir}/ingress.yaml"

print_info 'Configuring DNS for Tier1 Gateway...'

print_waiting 'Waiting for bookinfo IP...'
bookinfo_ip=$(k8s::get_service_address tsb-gateway-bookinfo bookinfo)
readonly bookinfo_ip

dns::update_cloud_dns_address "${BOOKINFO_FQDN}" "${bookinfo_ip}"
dns::update_cloud_dns_address "${DETAILS_FQDN}" "${bookinfo_ip}"

print_waiting "Waiting for DNS ${BOOKINFO_FQDN} to propogate..."
dns::waitDNS "${BOOKINFO_FQDN}" "${bookinfo_ip}"

echo "=========================="
echo "       TSB UI Access"
echo "--------------------------"
echo
echo "https://${MGMT_TSB_FQDN}"
echo
echo "   username: admin"
echo "   password: ${MGMT_TSB_ADMIN_PASSWORD}"
echo
echo "=========================="

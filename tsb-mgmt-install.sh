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
trap print_error ERR

# Install TSB into MGMT GKE Cluster

# Get MGMT GKE cluster k8s context
gcloud container clusters get-credentials "${MGMT_GKE_CLUSTER_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --zone="${MGMT_GKE_CLUSTER_ZONE}"

# Install Cert-Manager
printInfo 'Installing Cert Manager...'

# Known cert-manager issue with GKE may require elevated permissions
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole='cluster-admin' \
  --user="$(gcloud config get-value core/account)" || true # ignore errors

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

# Configure ClusterIssuer for GKE

readonly gen_mgmt_dir="${script_dir}/generated/mgmt"

mkdir -p "${gen_mgmt_dir}"

# Delete old Service Account if it exists
gcloud iam service-accounts delete "dns01-solver@${GCP_DNS_PROJECT_ID}.iam.gserviceaccount.com" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --quiet \
  || true # Ignore errors
gcloud iam service-accounts create dns01-solver \
  --project="${GCP_DNS_PROJECT_ID}" \
  --display-name='dns01-solver'
gcloud projects add-iam-policy-binding "${GCP_DNS_PROJECT_ID}" \
  --member="serviceAccount:dns01-solver@${GCP_DNS_PROJECT_ID}.iam.gserviceaccount.com" \
  --role='roles/dns.admin'

gcloud iam service-accounts keys create "${gen_mgmt_dir}/key.json" \
  --iam-account="dns01-solver@${GCP_DNS_PROJECT_ID}.iam.gserviceaccount.com" \
  --key-file-type='json'

# Delete old secret if it exists
kubectl delete secret clouddns-dns01-solver-svc-acct \
  --namespace='cert-manager' \
  || true # Ignore errors
kubectl create secret generic clouddns-dns01-solver-svc-acct \
  --namespace='cert-manager' \
  --from-file="${gen_mgmt_dir}/key.json"
# rm "${gen_mgmt_dir}/key.json"

cp "${script_dir}/templates/gke/cluster-issuer.yaml" "${gen_mgmt_dir}/cluster-issuer.yaml"
yq eval "(.spec.acme.email) |= \"${TSB_DNS_EMAIL}\"" \
  --inplace "${gen_mgmt_dir}/cluster-issuer.yaml"
yq eval "(.spec.acme.solvers[0].dns01.cloudDNS.project) |= \"${GCP_PROJECT_ID}\"" \
  --inplace "${gen_mgmt_dir}/cluster-issuer.yaml"
yq eval "(.spec.acme.solvers[0].selector.dnsZones[0]) |= \"${GCP_DNS_BASE_NAME}\"" \
  --inplace "${gen_mgmt_dir}/cluster-issuer.yaml"
kubectl apply --filename="${gen_mgmt_dir}/cluster-issuer.yaml"

# TSB Management Plane install
printInfo 'Installing TSB...'

tctl install manifest management-plane-operator \
  --registry="${DOCKER_REGISTRY}" >"${gen_mgmt_dir}/mp-operator.yaml"
kubectl apply --filename="${gen_mgmt_dir}/mp-operator.yaml"

printWaiting 'Waiting for TSB Management Operator to be ready...'
kubectl wait deployment/tsb-operator-management-plane \
  --namespace='tsb' \
  --for='condition=Available' \
  --timeout='10m'

tctl install manifest management-plane-secrets \
  --elastic-password="tsb-elastic-password" \
  --elastic-username="tsb" \
  --ldap-bind-dn="cn=admin,dc=tetrate,dc=io" \
  --ldap-bind-password="admin" \
  --postgres-password="tsb-postgres-password" \
  --postgres-username="tsb" \
  --tsb-admin-password="${MGMT_TSB_ADMIN_PASSWORD}" \
  --tsb-server-certificate="aaa" \
  --tsb-server-key="bbb" \
  --xcp-certs >"${gen_mgmt_dir}/mp-secrets.yaml"
kubectl apply --filename="${gen_mgmt_dir}/mp-secrets.yaml"

# Configure TSB TLS Cert

# cp "${script_dir}/templates/tsb/cert.yaml" "${gen_mgmt_dir}/"
# yq eval ".spec.dnsNames[0] |= \"${MGMT_TSB_FQDN}\"" \
#   --inplace "${gen_mgmt_dir}/cert.yaml"
# kubectl apply --filename="${gen_mgmt_dir}/cert.yaml"

# printWaiting 'Waiting for TSB Certificate to be ready...'
# kubectl wait certificate/tsb-certs \
#   --namespace='tsb' \
#   --for='condition=Ready' \
#   --timeout='10m'

# Assumes use of CertBot (helpers/gen-certs.sh)
readonly tetrate_certs_dir="${CERTS_DIR}/config/live/${TETRATE_DNS_SUFFIX}"

kubectl delete secret 'tsb-certs' \
  --namespace='tsb'
kubectl create secret tls 'tsb-certs' \
  --namespace='tsb' \
  --key="${tetrate_certs_dir}/privkey.pem" \
  --cert="${tetrate_certs_dir}/cert.pem"

printInfo 'Deploying TSB Management Plane...'

sleep 60s

cp "${script_dir}/templates/tsb/mp.yaml" "${gen_mgmt_dir}/"
yq eval ".spec.hub |= \"${DOCKER_REGISTRY}\"" \
  --inplace "${gen_mgmt_dir}/mp.yaml"
kubectl apply --filename="${gen_mgmt_dir}/mp.yaml"

printWaiting 'Waiting for TSB Management Plane to be ready...'

# Loop on `kubectl rollout status` as it takes a while for deployment/envoy to
# exist and then to complete
attempts=0
rollout_status_cmd='kubectl rollout status deployment/envoy --namespace=tsb'
until ${rollout_status_cmd} || [[ ${attempts} -eq 60 ]]; do
  attempts=$((attempts + 1))
  sleep 10
done
# kubectl wait deployment/envoy \
#   --namespace='tsb' \
#   --for='condition=Available' \
#   --timeout='10m'

kubectl create job teamsync-bootstrap \
  --namespace='tsb' \
  --from='cronjob/teamsync'
# kubectl wait job teamsync-bootstrap \
#   --namespace='tsb' \
#   --for='condition=Complete' \
#   --timeout="4m"

printInfo 'Configuring DNS for TSB mgmt cluster...'

TSB_IP_OLD=$(nslookup "${MGMT_TSB_FQDN}" | grep 'Address:' | tail -n1 | awk '{print $2}')

printWaiting 'Waiting for TSB IP...'
TSB_IP=$(getServiceAddress envoy tsb)
# until [[ -n "${TSB_IP}" ]]; do
#   sleep 5s
#   TSB_IP=$(getServiceAddress envoy tsb)
# done

printf "\nTSB_IP_OLD = %s\n" "${TSB_IP_OLD}"
printf "TSB_IP = %s\n\n" "${TSB_IP}"

# Cleanup tmp files from any previous (failed) update attempts
rm -f "${script_dir}/transaction.yaml"

# ignore failed deletions so that we can continue processing
# set +e
gcloud beta dns record-sets transaction start \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns record-sets transaction remove "${TSB_IP_OLD}" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}" \
  --name="${MGMT_TSB_FQDN}." \
  --ttl="300" \
  --type="A" \
  || true # Ignore errors
gcloud beta dns record-sets transaction add "${TSB_IP}" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}" \
  --name="${MGMT_TSB_FQDN}." \
  --ttl="300" \
  --type="A"
gcloud beta dns record-sets transaction execute \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}"
# set -e

printWaiting "Waiting for DNS ${MGMT_TSB_FQDN} to propogate..."
waitDNS "${MGMT_TSB_FQDN}" "${TSB_IP}"

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

printInfo 'Installing Management Cluster Control Plane...'

sleep 30s

# Copy Shared CA from getistio
kubectl create namespace istio-system
kubectl create secret generic cacerts \
  --namespace='istio-system' \
  --from-file="${ISTIO_CERTS_DIR}/ca-cert.pem" \
  --from-file="${ISTIO_CERTS_DIR}/ca-key.pem" \
  --from-file="${ISTIO_CERTS_DIR}/root-cert.pem" \
  --from-file="${ISTIO_CERTS_DIR}/cert-chain.pem"

# cp "${script_dir}/templates/tsb/mgmt-cluster.yaml" "${gen_mgmt_dir}/"
# yq eval ".metadata.name |= \"${MGMT_TSB_CLUSTER_NAME}\"" \
#   --inplace "${gen_mgmt_dir}/mgmt-cluster.yaml"
# yq eval ".metadata.organization |= \"${TSB_ORGANIZATION}\"" \
#   --inplace "${gen_mgmt_dir}/mgmt-cluster.yaml"
# tctl apply --file="${gen_mgmt_dir}/mgmt-cluster.yaml"

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

printWaiting 'Waiting for ControlPlane to be deployed...'
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
printWaiting 'Waiting for Istio control plane to be ready...'

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
# kubectl apply --filename - <<EOF
# apiVersion: cert-manager.io/v1
# kind: Certificate
# metadata:
#   name: bookinfo-certs
#   namespace: bookinfo
# spec:
#   secretName: bookinfo-certs
#   issuerRef:
#     name: letsencrypt-gke
#     kind: ClusterIssuer
#   dnsNames:
#     - ${BOOKINFO_FQDN}
# EOF

# printWaiting 'Waiting for Bookinfo Certificate to be ready...'
# kubectl wait certificate/bookinfo-certs \
#   --namespace='bookinfo' \
#   --for='condition=Ready' \
#   --timeout='10m'

# Assumes use of CertBot (helpers/gen-certs.sh)
readonly bookinfo_certs_dir="${CERTS_DIR}/config/live/${BOOKINFO_DNS_SUFFIX}"

kubectl --namespace='bookinfo' create secret tls 'bookinfo-certs' \
  --key="${bookinfo_certs_dir}/privkey.pem" \
  --cert="${bookinfo_certs_dir}/cert.pem"

cp "${script_dir}/templates/tsb/ingress.yaml" "${gen_mgmt_dir}/"
kubectl apply --filename="${gen_mgmt_dir}/ingress.yaml"

printInfo 'Configuring DNS for Tier1 Gateway...'

readonly bookinfo_ip_old=$(nslookup "${BOOKINFO_FQDN}" | grep 'Address:' | tail -n1 | awk '{print $2}')

printWaiting 'Waiting for bookinfo IP...'
readonly bookinfo_ip=$(getServiceAddress tsb-gateway-bookinfo bookinfo)

printf "\nbookinfo_ip_old = %s\n" "${bookinfo_ip_old}"
printf "bookinfo_ip = %s\n\n" "${bookinfo_ip}"

# Cleanup tmp files from any previous (failed) update attempts
rm -f "${script_dir}/transaction.yaml"

# ignore failed deletions so that we can continue processing
# set +e
gcloud beta dns record-sets transaction start \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}"
gcloud beta dns record-sets transaction remove "${bookinfo_ip_old}" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}" \
  --name="${BOOKINFO_FQDN}." \
  --ttl="300" \
  --type="A" \
  || true # Ignore errors
gcloud beta dns record-sets transaction add "${bookinfo_ip}" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}" \
  --name="${BOOKINFO_FQDN}." \
  --ttl="300" \
  --type="A"
gcloud beta dns record-sets transaction remove "${bookinfo_ip_old}" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}" \
  --name="${DETAILS_FQDN}." \
  --ttl="300" \
  --type="A" \
  || true # Ignore errors
gcloud beta dns record-sets transaction add "${bookinfo_ip}" \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}" \
  --name="${DETAILS_FQDN}." \
  --ttl="300" \
  --type="A"
gcloud beta dns record-sets transaction execute \
  --project="${GCP_DNS_PROJECT_ID}" \
  --zone="${GCP_DNS_ZONE_ID}"
# set -e

printWaiting "Waiting for DNS ${BOOKINFO_FQDN} to propogate..."
waitDNS "${BOOKINFO_FQDN}" "${bookinfo_ip}"

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

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
trap print_error ERR

readonly APP_TSB_CLUSTER_NAME='tsb-app-openshift-gcp'
readonly APP_TSB_CLUSTER_REGION='us-east4'

readonly gen_dir="${script_dir}/generated/openshift/app"

mkdir -p "${gen_dir}"

readonly OC_CMD="./oc"

# Install TSB Control Plane (aka Istio) into APP Cluster

# Set Kubernetes Current Context to the GKE MGMT Cluster
gcloud container clusters get-credentials "${MGMT_GKE_CLUSTER_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --zone="${MGMT_GKE_CLUSTER_ZONE}"

# Configure TSB
cat <<EOF >"${gen_dir}/tsb.yaml"
apiVersion: api.tsb.tetrate.io/v2
kind: Cluster
metadata:
  organization: ${TSB_ORGANIZATION}
  name: ${APP_TSB_CLUSTER_NAME}
spec:
  tokenTtl: "8760h"
  locality:
    region: ${APP_TSB_CLUSTER_REGION}
EOF
tctl apply -f "${gen_dir}/tsb.yaml"

# Get Bookinfo cert (secret) from Mgmt cluster to put into App clusters

readonly certs_dir="${script_dir}/generated/certs"

mkdir -p "${certs_dir}"

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

tctl install manifest cluster-operators \
  --registry "${DOCKER_REGISTRY}" \
  >"${gen_dir}/clusteroperators.yaml"

tctl install manifest control-plane-secrets \
  --allow-defaults \
  --elastic-password='tsb-elastic-password' \
  --elastic-username='tsb' \
  --xcp-certs="$(tctl install cluster-certs --cluster="${APP_TSB_CLUSTER_NAME}")" \
  --cluster="${APP_TSB_CLUSTER_NAME}" \
  >"${gen_dir}/controlplane-secrets.yaml"

export KUBECONFIG="${script_dir}/generated/openshift/auth/kubeconfig"

${OC_CMD} adm policy add-scc-to-user anyuid \
    system:serviceaccount:istio-system:tsb-operator-control-plane
${OC_CMD} adm policy add-scc-to-user anyuid \
    system:serviceaccount:istio-gateway:tsb-operator-data-plane

${OC_CMD} create namespace istio-system
${OC_CMD} create secret generic cacerts \
  --namespace='istio-system' \
  --from-file="${ISTIO_CERTS_DIR}/ca-cert.pem" \
  --from-file="${ISTIO_CERTS_DIR}/ca-key.pem" \
  --from-file="${ISTIO_CERTS_DIR}/root-cert.pem" \
  --from-file="${ISTIO_CERTS_DIR}/cert-chain.pem"

${OC_CMD} apply --filename="${gen_dir}/clusteroperators.yaml"

printWaiting 'Waiting for TSB APP ControlPlane to be deployed...'
${OC_CMD} wait deployment/tsb-operator-control-plane \
  --namespace='istio-system' \
  --for='condition=Available' \
  --timeout='4m'

# sleep 10s

${OC_CMD} apply --filename="${gen_dir}/controlplane-secrets.yaml"

sleep 30s

${OC_CMD} apply --filename - <<EOF
apiVersion: install.tetrate.io/v1alpha1
kind: ControlPlane
metadata:
  name: ${APP_TSB_CLUSTER_NAME}
  namespace: istio-system
spec:
  components:
    oap:
      kubeSpec:
        overlays:
          - apiVersion: extensions/v1beta1
            kind: Deployment
            name: oap-deployment
            patches:
              - path: spec.template.spec.containers.[name:oap].env.[name:SW_CORE_GRPC_SSL_CERT_CHAIN_PATH].value
                value: /skywalking/pkin/tls.crt
              - path: spec.template.spec.containers.[name:oap].env.[name:SW_CORE_GRPC_SSL_TRUSTED_CA_PATH].value
                value: /skywalking/pkin/tls.crt
        service:
          annotations:
            service.beta.openshift.io/serving-cert-secret-name: dns.oap-service-account
    istio:
      kubeSpec:
        CNI:
          binaryDirectory: /var/lib/cni/bin
          chained: false
          configurationDirectory: /etc/cni/multus/net.d
          configurationFileName: istio-cni.conf
        overlays:
          - apiVersion: install.istio.io/v1alpha1
            kind: IstioOperator
            name: tsb-istiocontrolplane
            patches:
              - path: spec.meshConfig.defaultConfig.envoyAccessLogService.address
                value: oap.istio-system.svc:11800
              - path: spec.meshConfig.defaultConfig.envoyAccessLogService.tlsSettings.caCertificates
                value: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
              - path: spec.values.cni.chained
                value: false
              - path: spec.values.sidecarInjectorWebhook
                value:
                  injectedAnnotations:
                    k8s.v1.cni.cncf.io/networks: istio-cni
      traceSamplingRate: 100
  hub: $(jq '.spec.hub' <<<"${mgmt_cp_json}")
  managementPlane:
    host: $(jq --raw-output '.spec.managementPlane.host' <<<"${mgmt_cp_json}")
    port: $(jq --raw-output '.spec.managementPlane.port' <<<"${mgmt_cp_json}")
    clusterName: ${APP_TSB_CLUSTER_NAME}
  telemetryStore:
    elastic:
      host: $(jq --raw-output '.spec.telemetryStore.elastic.host' <<<"${mgmt_cp_json}")
      port: $(jq --raw-output '.spec.telemetryStore.elastic.port' <<<"${mgmt_cp_json}")
      version: $(jq --raw-output '.spec.telemetryStore.elastic.version' <<<"${mgmt_cp_json}")
  meshExpansion: {}
EOF

# Edge is last thing to start
printWaiting 'Waiting for Istio control plane to be ready...'

# Loop on `kubectl rollout status` as it takes a while for deployment/envoy to
# exist and then to complete
attempts=0
rollout_status_cmd="${OC_CMD} rollout status deployment/edge --namespace=istio-system"
until ${rollout_status_cmd} || [[ ${attempts} -eq 60 ]]; do
  attempts=$((attempts + 1))
  sleep 10s
done

# Install Bookinfo Sample Application
# bash -c "${script_dir}/bookinfo-install.sh"

# Install Bookinfo Sample Application
${OC_CMD} create namespace bookinfo
${OC_CMD} label namespace bookinfo 'istio-injection=enabled'

${OC_CMD} -n 'bookinfo' create -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF

${OC_CMD} adm policy add-scc-to-group anyuid system:serviceaccounts:bookinfo

${OC_CMD} apply --namespace='bookinfo' \
  --filename='https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml'

until [[ $(${OC_CMD} get pods --namespace='bookinfo' | grep -c Running) -eq 6 ]]; do
  echo 'Waiting for bookinfo app to deploy...'
  sleep 5s
done

sleep 10s

${OC_CMD} exec "$(
    kubectl get pod \
      --namespace='bookinfo' \
      --selector='app=ratings' \
      --output=jsonpath='{.items[0].metadata.name}'
  )" \
  --namespace='bookinfo' \
  --container='ratings'\
  -- curl --silent productpage:9080/productpage \
  | grep --only-matching '<title>.*</title>'

# Create TSB Ingress Gateway
${OC_CMD} --namespace='bookinfo' create secret tls 'bookinfo-certs' \
  --key="${certs_dir}/bookinfo.key" \
  --cert="${certs_dir}/bookinfo.crt"

cp "${script_dir}/templates/tsb/ingress.yaml" "${gen_dir}"
${OC_CMD} apply --filename="${gen_dir}/ingress.yaml"

# bookinfo_gateway_ip=$(getServiceAddress tsb-gateway-bookinfo bookinfo)
svc='tsb-gateway-bookinfo'
ns='bookinfo'
addr=""
until [[ -n ${addr} ]]; do
  addr=$(kubectl get service "${svc}" --namespace="${ns}" --output=jsonpath="{.status.loadBalancer.ingress[0].ip}")
  if [[ -z "${addr}" ]]; then
    addr=$(kubectl get service "${svc}" --namespace="${ns}" --output=jsonpath="{.status.loadBalancer.ingress[0].hostname}")
  fi
  sleep 5s
done
bookinfo_gateway_ip=${addr}

printf '\nbookinfo_ingress_ip = %s\n\n' "${bookinfo_gateway_ip}"

curl --silent --verbose "https://${BOOKINFO_FQDN}/productpage" \
  --resolve "${BOOKINFO_FQDN}:443:${bookinfo_gateway_ip}" \
  | grep --only-matching '<title>.*</title>'

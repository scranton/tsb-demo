#!/usr/bin/env bash
#
# Install Bookinfo Sample Application into current Kubernetes context

# Get directory this script is located in to access script local files
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "${script_dir}/setenv.sh"

set -u

# Install Bookinfo Sample Application
kubectl create namespace bookinfo
kubectl label namespace bookinfo 'istio-injection=enabled'
# kubectl apply --namespace='bookinfo' \
#   --filename='https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml'
kubectl apply --namespace='bookinfo' \
  --filename="${script_dir}/bookinfo.yaml"

until [[ $(kubectl get pods --namespace='bookinfo' | grep -c Running) -eq 6 ]]; do
  echo 'Waiting for bookinfo app to deploy...'
  sleep 5s
done

sleep 10s

kubectl exec "$(
    kubectl get pod \
      --namespace='bookinfo' \
      --selector='app=ratings' \
      --output=jsonpath='{.items[0].metadata.name}'
  )" \
  --namespace='bookinfo' \
  --container='ratings'\
  -- curl --silent productpage:9080/productpage \
  | grep --only-matching '<title>.*</title>'

#!/usr/bin/env bash

# Get directory this script is located in to access script local files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

set -eu

kubectl create namespace sleep
kubectl label namespace sleep istio-injection=enabled --overwrite=true
kubectl apply -n sleep -f "${SCRIPT_DIR}/sleep-service.yaml"

# Wait for sleep service to deploy
kubectl rollout status -n sleep deployment/sleep

# Test access; should succeed
kubectl exec "$(kubectl get pod -l app=sleep -n sleep -o jsonpath={.items..metadata.name})" -c sleep -n sleep -- curl --silent -v http://productpage.bookinfo:9080/productpage | grep -o "<title>.*</title>"

# Limit Kubernetes Service to Service communition to only those within same TSB Workspace
tctl apply -f "${SCRIPT_DIR}/sleep-security.yaml"

sleep 10s

# Test access; should fail with '403 Forbidden; RBAC: access denied'
kubectl exec "$(kubectl get pod -l app=sleep -n sleep -o jsonpath={.items..metadata.name})" -c sleep -n sleep -- curl --silent -v http://productpage.bookinfo:9080/productpage

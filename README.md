# Tetrate Service Bridge (TSB) Demo

Shows TSB using Istio Bookinfo application across two Kubernetes clusters in different
regions and a TSB Tier1 Gateway deployed in a third Kubenetes cluster and region.
Scripts can currently work with any combination of GKE and AKS. AWS EKS to be added soon.

## Requirements

Tooling

* gcloud cli
* az cli
* kubectl
* jq
* tctl
* helm
* yq

## Running

Update `setenv.sh` in the repo's root directory with your information, and then run

```shell
./demo-create.sh
```

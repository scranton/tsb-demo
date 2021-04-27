# Tetrate Service Bridge (TSB) Demo

Shows TSB using Istio Bookinfo application across two GKE clusters in different regions and a TSB Tier1 Gateway deployed in a third GKE cluster and region.

## Requirements

Tooling

* gcloud
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

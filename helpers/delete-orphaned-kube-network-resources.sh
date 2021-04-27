#!/usr/bin/env bash
#
# A utility for deleting google cloud network load-balancers that are unattached to active
# kubernetes' services.
#
# This script is necessary due to bugs in GKE/Kubernetes right now (Feb 2017) that prevent
# gcloud load-balancer resource objects from being cleaned up properly.
#
# Note that a google "load-balancer" is not a single object, it is a combination of 3 objects:
# firewall-rule / forwarding-rule / target-pool. This script will try to delete all related objects.
# the objects following a common naming pattern so they're able to be linked by name.
#
# References:
# - (kube issue cited by google support): https://github.com/kubernetes/kubernetes/issues/4630
# - (based on): https://github.com/pantheon-systems/kube-gce-cleanup
#
# USAGE:
#
#   $ PROJECT=fooproject \
#     REGION=us-central1 \
#     GKE_CLUSTER_NAME=cluster-01 \
#   ./delete-orphaned-kube-network-resources.sh

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

set -eou pipefail

readonly DRYRUN=${DRYRUN:-}
readonly PROJECT=${PROJECT:-}
readonly REGION=${REGION:-}
readonly GKE_CLUSTER_NAME=${GKE_CLUSTER_NAME:-}
readonly KUBERNETES_SERVICE_HOST=${KUBERNETES_SERVICE_HOST:-}

total=0
deleted=0
verb='should be deleted'

# shellcheck source=helpers/delete-orphans.bash
source "${SCRIPT_DIR}/delete-orphans.bash"

main() {
    if [[ -z "${DRYRUN}" ]] ; then
        verb='Deleted'
    fi

    validate
    check_target_pools
    check_firewalls

    echo "${verb}: ${deleted}"
    echo "scanned: ${total}"
}

main

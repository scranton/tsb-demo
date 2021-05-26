#!/usr/bin/env bash
#
# Generate Traffic

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

# Load shared Environment Variables
source "${script_dir}/setenv.sh"

# Load shared functions
source "${script_dir}/helpers/common_scripts.bash"

set -u
trap print_trap_error ERR

gateway_ip=$1

if [[ -z ${gateway_ip} ]]; then
  gateway_ip=$(k8s::get_service_address 'tsb-gateway-bookinfo' 'bookinfo')
fi

printf '\ngateway_ip = %s\n\n' "${gateway_ip}"

while true; do
  result=$(
    curl \
      --max-time 5 \
      --silent \
      --output /dev/null \
      --head \
      --write-out '%{http_code}' \
      "https://${BOOKINFO_FQDN}/productpage" \
      --resolve "${BOOKINFO_FQDN}:443:${gateway_ip}"
  )
  echo "date: $(date),  status code: ${result}"
  sleep 10
done

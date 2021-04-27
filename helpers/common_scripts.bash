#!/usr/bin/env bash

# Color Prompts
readonly NOCOLOR='\e[0m'
readonly RED='\e[31m'
readonly YELLOW='\e[33m'
readonly BLUE='\e[34m'

readonly BOLDRED="\e[1;${RED}"

function printWaiting() {
  printf "⏳ ${YELLOW}%s${NOCOLOR}\n" "$1"
}

function printInfo() {
  printf "${BLUE}==> %s${NOCOLOR}\n" "$1"
}

function print_error() {
  read -r line file <<<"$(caller)"
  echo -e "${BOLDRED}An error occurred in line ${line} of file ${file}:${NOCOLOR}" >&2
  printf "${BOLDRED}==> %s${NOCOLOR}\n" "$(sed "${line}q;d" "${file}")" >&2
}

function getServiceAddress() {
  local svc="$1"
  local ns="$2"
  local addr=""

  until [[ -n ${addr} ]]; do
    addr=$(kubectl get service "${svc}" --namespace="${ns}" --output=jsonpath="{.status.loadBalancer.ingress[0].ip}")
    if [[ -z "${addr}" ]]; then
      addr=$(kubectl get service "${svc}" --namespace="${ns}" --output=jsonpath="{.status.loadBalancer.ingress[0].hostname}")
    fi
    sleep 5s
  done
  echo "${addr}"
}

#######################################
# Waits till DNS name is associated with an IP
# Will timeout after 5minutes (5 * 60 tries * 1 sec wait = 300 secs)
# Arguments:
#   DNS_NAME
#   TARGET_IP
# Outputs:
#   0 if DNS is associated with IP; non-zero on error.
#######################################
function waitDNS() {
  local dns_name="$1"
  local target_ip="$2"
  local dns_ip=""
  local counter=0

  until [[ "${dns_ip}" == "${target_ip}" ]] || [[ ${counter} -gt 300 ]]; do
    dns_ip=$(nslookup "${dns_name}" | awk '/^Address: / { print $2 }')
    if [[ "${dns_ip}" != "${target_ip}" ]]; then
      sleep 5s
    fi
    ((counter++))
  done
  if [[ "${dns_ip}" != "${target_ip}" ]]; then
    printf "${BOLDRED}ERROR: For DNS NAME '%s', expected IP '%s' and got '%s" "${dns_name}" "${target_ip}" "${dns_ip}"
    return 1
  fi
  return 0
}

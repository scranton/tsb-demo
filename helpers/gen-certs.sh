#!/usr/bin/env bash
#
# Configure TSB demo
# see https://certbot.eff.org/docs/install.html#running-with-docker

# Get directory this script is located in to access script local files
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly script_dir

# Load shared Environment Variables
# shellcheck source=setenv.sh
source "${script_dir}/../setenv.sh"

# Load shared functions
# shellcheck source=helpers/common_scripts.bash
source "${script_dir}/common_scripts.bash"

set -u
trap print_trap_error ERR

readonly certs_dir=${CERTS_DIR}
readonly secrets_dir=${SECRETS_DIR}

mkdir -p "${certs_dir}" "${secrets_dir}"

gcloud iam service-accounts create certbot \
  --project="${GCP_PROJECT_ID}" \
  --display-name='certbot'
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
  --member="serviceAccount:certbot@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role='roles/dns.admin'
gcloud iam service-accounts keys create "${secrets_dir}/${GCP_PROJECT_ID}-key.json" \
  --iam-account="certbot@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --key-file-type='json'

# Create Bookinfo Cert
sudo docker run -it --rm --name certbot \
  -v "/etc/letsencrypt:/etc/letsencrypt" \
  -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
  -v "${secrets_dir}:/mnt/secrets" \
  -v "${certs_dir}:/mnt/certbot" \
  certbot/dns-google certonly \
    -n \
    --agree-tos \
    --email "${TSB_DNS_EMAIL}" \
    --dns-google \
    --dns-google-credentials "/mnt/secrets/${GCP_PROJECT_ID}-key.json" \
    --dns-google-propagation-seconds 120 \
    -d "${BOOKINFO_DNS_SUFFIX}" \
    -d "productpage.${BOOKINFO_DNS_SUFFIX}" \
    -d "details.${BOOKINFO_DNS_SUFFIX}" \
    -d "reviews.${BOOKINFO_DNS_SUFFIX}" \
    -d "ratings.${BOOKINFO_DNS_SUFFIX}" \
    --config-dir /mnt/certbot/config \
    --logs-dir /mnt/certbot/logs \
    --work-dir /mnt/certbot/work

# Create TSB Cert
sudo docker run -it --rm --name certbot \
  -v "/etc/letsencrypt:/etc/letsencrypt" \
  -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
  -v "${secrets_dir}:/mnt/secrets" \
  -v "${certs_dir}:/mnt/certbot" \
  certbot/dns-google certonly \
    -n \
    --agree-tos \
    --email "${TSB_DNS_EMAIL}" \
    --dns-google \
    --dns-google-credentials "/mnt/secrets/${GCP_PROJECT_ID}-key.json" \
    --dns-google-propagation-seconds 120 \
    -d "${TETRATE_DNS_SUFFIX}" \
    -d "tsb.${TETRATE_DNS_SUFFIX}" \
    --config-dir /mnt/certbot/config \
    --logs-dir /mnt/certbot/logs \
    --work-dir /mnt/certbot/work

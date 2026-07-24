#!/usr/bin/env bash
# Demo 網站預期是公開展示用，部署完之後幫每個客戶的 Cloud Run service 開放
# allUsers 可呼叫（roles/run.invoker）。第一次部署新 service 時 Cloud Run
# 預設不開放未驗證存取，需要額外這一步，否則會看到 403 Forbidden。
#
# ./make-services-public.sh [customers.yaml 路徑]

set -euo pipefail

CUSTOMERS_FILE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/customers.yaml}"

command -v yq >/dev/null || { echo "需要先安裝 yq: brew install yq" >&2; exit 1; }

while IFS=$'\t' read -r id project region service; do
  echo "=== ${id} (${project}) ==="
  gcloud run services add-iam-policy-binding "$service" \
    --project="$project" --region="$region" \
    --member="allUsers" --role="roles/run.invoker" --quiet
  URL=$(gcloud run services describe "$service" --project="$project" --region="$region" --format="value(status.url)")
  echo "  URL: ${URL}"
done < <(yq e '.customers[] | [.id, .project_id, .region, .service_name] | @tsv' "$CUSTOMERS_FILE")

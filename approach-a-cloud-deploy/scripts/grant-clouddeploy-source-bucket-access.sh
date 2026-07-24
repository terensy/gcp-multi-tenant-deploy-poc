#!/usr/bin/env bash
# Cloud Deploy 的「原始碼上傳」暫存 bucket 命名是 <hash>_clouddeploy，這個 hash
# 在 Target/Pipeline 第一次建立、跑過至少一次 release 之前無法預先推算，所以無法
# 放進 terraform/onboarding（沒有穩定的資源位址可以參照）。
#
# 用法：在 gcloud deploy apply 過 pipeline，且至少嘗試觸發過一次 release 之後
# （即使那次 release 因為這個權限缺失而失敗也沒關係，bucket 屆時已經被建出來），
# 執行這支腳本，讀 customers.yaml 幫每個客戶的 deployer SA 補上這個 bucket的讀取權限。
#
# ./grant-clouddeploy-source-bucket-access.sh [mgmt_project_id]

set -euo pipefail

MGMT_PROJECT="${1:-gcpdeploy-poc-mgmt}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CUSTOMERS_FILE="$ROOT_DIR/customers.yaml"

command -v yq >/dev/null || { echo "需要先安裝 yq: brew install yq" >&2; exit 1; }

BUCKET=$(gcloud storage buckets list --project="$MGMT_PROJECT" --format="value(name)" 2>&1 | grep '_clouddeploy$' || true)

if [[ -z "$BUCKET" ]]; then
  echo "在 ${MGMT_PROJECT} 找不到 *_clouddeploy 的 bucket。" >&2
  echo "請先用 gcloud deploy apply 建立 pipeline，並嘗試觸發至少一次 release 後再執行本腳本。" >&2
  exit 1
fi

echo "找到 Cloud Deploy 原始碼暫存 bucket: gs://${BUCKET}"

while IFS=$'\t' read -r id deployer_sa; do
  echo "=== 授權 ${deployer_sa} 讀取 gs://${BUCKET} ==="
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
    --member="serviceAccount:${deployer_sa}" \
    --role="roles/storage.objectViewer"
done < <(yq e '.customers[] | [.id, .deployer_sa] | @tsv' "$CUSTOMERS_FILE")

echo "完成。"

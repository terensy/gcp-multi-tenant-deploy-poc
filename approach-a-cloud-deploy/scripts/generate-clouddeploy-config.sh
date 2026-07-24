#!/usr/bin/env bash
# 這支腳本示範「客戶數量持續增加時，Cloud Deploy 設定如何自動維護」，
# 而不是每次新增客戶都要手動改 clouddeploy.yaml。
#
# 用法：
#   ./generate-clouddeploy-config.sh [region] [mgmt_project_id]
#
# 依賴：yq v4+ (https://github.com/mikefarah/yq)
#
# 流程：讀取 ../../customers.yaml -> 幫每個客戶產生一個 Target 區塊
#       -> 產生 all-customers 這個 multiTarget，targetIds 為所有客戶 id
#       -> 與 clouddeploy-base.yaml 合併成 clouddeploy.generated.yaml
#       -> 印出套用指令（不自動執行，讓使用者先檢查產生的內容再 apply）

set -euo pipefail

REGION="${1:-asia-east1}"
MGMT_PROJECT="${2:-gcpdeploy-poc-mgmt}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUSTOMERS_FILE="$ROOT_DIR/../customers.yaml"
BASE_FILE="$ROOT_DIR/clouddeploy-base.yaml"
OUT_FILE="$ROOT_DIR/clouddeploy.generated.yaml"

command -v yq >/dev/null || { echo "需要先安裝 yq: brew install yq" >&2; exit 1; }

cp "$BASE_FILE" "$OUT_FILE"

target_ids=()
while IFS=$'\t' read -r id project_id region_val service_name deployer_sa; do
  target_ids+=("$id")
  cat >> "$OUT_FILE" <<EOF
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: ${id}
description: Demo site target for ${project_id}
run:
  location: projects/${project_id}/locations/${region_val}
executionConfigs:
  - usages: [RENDER, DEPLOY]
    serviceAccount: ${deployer_sa}
deployParameters:
  customer-id: "${id}"
EOF
done < <(yq e '.customers[] | [.id, .project_id, .region, .service_name, .deployer_sa] | @tsv' "$CUSTOMERS_FILE")

{
  echo "---"
  echo "apiVersion: deploy.cloud.google.com/v1"
  echo "kind: Target"
  echo "metadata:"
  echo "  name: all-customers"
  echo "description: 所有客戶 Project 的平行部署群組（自動產生，勿手動編輯）"
  echo "multiTarget:"
  echo "  targetIds:"
  for id in "${target_ids[@]}"; do
    echo "    - ${id}"
  done
} >> "$OUT_FILE"

echo "已產生 ${OUT_FILE}，共 ${#target_ids[@]} 個客戶 Target"
echo ""
echo "檢查無誤後執行以下指令套用到 Cloud Deploy："
echo "  gcloud deploy apply --file=${OUT_FILE} --region=${REGION} --project=${MGMT_PROJECT}"

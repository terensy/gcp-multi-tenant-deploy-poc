#!/usr/bin/env bash
# 從 GCP Folder 動態掃描客戶 Project，取代 customers.yaml 手動維護清單。
#
# 前提（由另外的 Terraform onboarding 保證，不在這支腳本處理範圍內）：
#   - 丟進這個 Folder 的每個 Project，都已經先跑過 onboarding，具備標準命名的
#     deployer@<project-id>.iam.gserviceaccount.com service account，且該 SA
#     已有 run.developer / actAs / Artifact Registry reader 等必要權限。
#   - 所有客戶都用同一個 region、同一個 Cloud Run service 名稱（demo-site）。
#
# 用法：
#   ./generate-clouddeploy-config-from-folder.sh <FOLDER_ID> [region] [mgmt_project_id]

set -euo pipefail

FOLDER_ID="${1:?請提供 GCP Folder ID}"
REGION="${2:-asia-east1}"
MGMT_PROJECT="${3:-gcpdeploy-poc-mgmt}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_FILE="$ROOT_DIR/clouddeploy-base.yaml"
OUT_FILE="$ROOT_DIR/clouddeploy.generated.yaml"

list_customer_projects() {
  gcloud projects list \
    --filter="parent.id=${FOLDER_ID} AND parent.type=folder" \
    --format="value(projectId)" \
    | grep -v "^${MGMT_PROJECT}$" || true
}

if [[ -z "$(list_customer_projects)" ]]; then
  echo "在 Folder ${FOLDER_ID} 底下沒掃到任何客戶 Project（已排除管理 Project ${MGMT_PROJECT}）" >&2
  exit 1
fi

cp "$BASE_FILE" "$OUT_FILE"

count=0
while IFS= read -r project_id; do
  count=$((count + 1))
  cat >> "$OUT_FILE" <<EOF
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: ${project_id}
description: Demo site target for ${project_id}（Folder 動態掃描產生，勿手動編輯）
run:
  location: projects/${project_id}/locations/${REGION}
executionConfigs:
  - usages: [RENDER, DEPLOY]
    serviceAccount: deployer@${project_id}.iam.gserviceaccount.com
deployParameters:
  customer-id: "${project_id}"
EOF
done < <(list_customer_projects)

{
  echo "---"
  echo "apiVersion: deploy.cloud.google.com/v1"
  echo "kind: Target"
  echo "metadata:"
  echo "  name: all-customers"
  echo "description: 所有客戶 Project 的平行部署群組（Folder 動態掃描產生，勿手動編輯）"
  echo "multiTarget:"
  echo "  targetIds:"
  while IFS= read -r project_id; do
    echo "    - ${project_id}"
  done < <(list_customer_projects)
} >> "$OUT_FILE"

echo "已從 Folder ${FOLDER_ID} 掃到 ${count} 個客戶 Project，產生 ${OUT_FILE}"
echo ""
echo "套用："
echo "  gcloud deploy apply --file=${OUT_FILE} --region=${REGION} --project=${MGMT_PROJECT}"

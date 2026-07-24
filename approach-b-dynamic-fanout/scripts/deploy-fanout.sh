#!/usr/bin/env bash
# 動態 fan-out 部署：讀取 customers.yaml，平行（有上限併發數）呼叫
# gcloud run deploy 部署到每一個客戶 Project。
#
# 新增客戶時完全不用改這支腳本或任何部署設定，只要 customers.yaml 多一筆即可。
#
# 用法：
#   ./deploy-fanout.sh <image> [customers.yaml 路徑] [最大併發數]
# 範例：
#   ./deploy-fanout.sh asia-east1-docker.pkg.dev/gcpdeploy-poc-mgmt/demo-site/app:abc123

set -euo pipefail

IMAGE="${1:?請提供完整 image 路徑，例如 asia-east1-docker.pkg.dev/gcpdeploy-poc-mgmt/demo-site/app:TAG}"
CUSTOMERS_FILE="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/customers.yaml}"
MAX_PARALLEL="${3:-10}"

command -v yq >/dev/null || { echo "需要先安裝 yq: brew install yq" >&2; exit 1; }

LOG_DIR="$(mktemp -d)"
echo "個別部署 log 存放於: ${LOG_DIR}"

deploy_one() {
  local id="$1" project="$2" region="$3" service="$4" deployer_sa="$5"
  if gcloud run deploy "$service" \
      --image="$IMAGE" \
      --project="$project" \
      --region="$region" \
      --impersonate-service-account="$deployer_sa" \
      --quiet > "${LOG_DIR}/${id}.log" 2>&1; then
    echo "[OK]   ${id} (${project})"
  else
    echo "[FAIL] ${id} (${project}) -- 詳見 ${LOG_DIR}/${id}.log"
    return 1
  fi
}

running=0
failed=0

while IFS=$'\t' read -r id project region service deployer_sa; do
  deploy_one "$id" "$project" "$region" "$service" "$deployer_sa" &
  running=$((running + 1))
  if (( running >= MAX_PARALLEL )); then
    wait -n || failed=$((failed + 1))
    running=$((running - 1))
  fi
done < <(yq e '.customers[] | [.id, .project_id, .region, .service_name, .deployer_sa] | @tsv' "$CUSTOMERS_FILE")

# 等待所有還在跑的部署完成
while (( running > 0 )); do
  wait -n || failed=$((failed + 1))
  running=$((running - 1))
done

echo ""
echo "全部客戶部署觸發完成（失敗數: ${failed}），逐筆結果請見上方 [OK]/[FAIL]"
[[ "$failed" -eq 0 ]]

#!/usr/bin/env bash
# 手動觸發一次完整的 CI/CD：build image → push 到 Artifact Registry →
# 建立 Cloud Deploy Release → 平行 rollout 到所有客戶 Project。
#
# 用法：
#   ./deploy.sh [mgmt_project_id] [region]
# 範例：
#   ./deploy.sh gcpdeploy-poc-mgmt asia-east1

set -euo pipefail

MGMT_PROJECT="${1:-gcpdeploy-poc-mgmt}"
REGION="${2:-asia-east1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAG="$(date +%Y%m%d-%H%M%S)"
IMAGE="${REGION}-docker.pkg.dev/${MGMT_PROJECT}/demo-site/app:${TAG}"

echo "=== [1/2] Build + Push image: ${IMAGE} ==="
gcloud builds submit \
  --project="$MGMT_PROJECT" \
  --tag="$IMAGE" \
  "$ROOT_DIR"

echo ""
echo "=== [2/2] 建立 Cloud Deploy Release，平行部署到所有客戶 ==="
"$ROOT_DIR/approach-a-cloud-deploy/scripts/create-release.sh" "$TAG" "$REGION" "$MGMT_PROJECT"

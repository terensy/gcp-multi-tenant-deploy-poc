#!/usr/bin/env bash
# 觸發一次「平行部署到所有客戶」的 Release。
# 前提：clouddeploy.generated.yaml 已用 generate-clouddeploy-config.sh 產生並 apply 過。
#
# 用法：
#   ./create-release.sh <image-tag> [region] [mgmt_project_id]
# 範例：
#   ./create-release.sh $(git rev-parse --short HEAD)

set -euo pipefail

IMAGE_TAG="${1:?請提供 image tag，例如 git commit sha}"
REGION="${2:-asia-east1}"
MGMT_PROJECT="${3:-gcpdeploy-poc-mgmt}"
RELEASE_NAME="release-$(date +%Y%m%d-%H%M%S)"

gcloud deploy releases create "$RELEASE_NAME" \
  --project="$MGMT_PROJECT" \
  --region="$REGION" \
  --delivery-pipeline=demo-site-pipeline \
  --images="asia-east1-docker.pkg.dev/${MGMT_PROJECT}/demo-site/app=asia-east1-docker.pkg.dev/${MGMT_PROJECT}/demo-site/app:${IMAGE_TAG}"

echo ""
echo "已建立 Release：${RELEASE_NAME}"
echo "查看所有客戶的平行 rollout 狀態："
echo "  gcloud deploy rollouts list --release=${RELEASE_NAME} --delivery-pipeline=demo-site-pipeline --project=${MGMT_PROJECT} --region=${REGION}"

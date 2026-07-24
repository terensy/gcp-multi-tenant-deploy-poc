# 客戶 Onboarding 用的共用 Terraform module。
# 兩個方案都需要「新增客戶 Project 時自動把跨 Project 部署權限設好」，
# 差別只在方案 A 另外還需要 Cloud Deploy Target 註冊（見 approach-a-cloud-deploy/scripts）。
#
# 設計重點：customers.yaml 是唯一資料來源。新增一個客戶 = 在 customers.yaml 多一筆，
# 這裡的 for_each 就會自動多產生一組 IAM 綁定，不需要手動維護。

locals {
  customers       = yamldecode(file("${path.module}/../../customers.yaml")).customers
  customers_by_id = { for c in local.customers : c.id => c }
}

data "google_project" "mgmt" {
  project_id = var.mgmt_project_id
}

data "google_project" "customer" {
  for_each   = local.customers_by_id
  project_id = each.value.project_id
}

resource "google_project_service" "run" {
  for_each = local.customers_by_id
  project  = each.value.project_id
  service  = "run.googleapis.com"
}

# 每個客戶 Project 各自的 deployer service account
# （由這個 SA 在自己的 Project 內執行部署，而不是用一個橫跨所有 Project 的萬用 SA）
resource "google_service_account" "deployer" {
  for_each     = local.customers_by_id
  project      = each.value.project_id
  account_id   = "deployer"
  display_name = "Deploy execution SA for ${each.key}"
}

resource "google_project_iam_member" "run_developer" {
  for_each = local.customers_by_id
  project  = each.value.project_id
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

resource "google_project_iam_member" "sa_user" {
  for_each = local.customers_by_id
  project  = each.value.project_id
  role     = "roles/iam.serviceAccountUser"
  member   = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

# 方案 A：讓管理 Project 的 Cloud Deploy service agent 能「代表」
# 這個跨 Project 的 deployer SA 執行 render/deploy
resource "google_service_account_iam_member" "clouddeploy_can_actas" {
  for_each           = local.customers_by_id
  service_account_id = google_service_account.deployer[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.mgmt.number}@gcp-sa-clouddeploy.iam.gserviceaccount.com"
}

resource "google_service_account_iam_member" "cloudbuild_agent_can_actas" {
  for_each           = local.customers_by_id
  service_account_id = google_service_account.deployer[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.mgmt.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

# 方案 B：讓「動態 fan-out」用的 Cloud Build 執行身分能 impersonate 各客戶的 deployer SA
resource "google_service_account_iam_member" "fanout_can_actas" {
  for_each           = local.customers_by_id
  service_account_id = google_service_account.deployer[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.fanout_orchestrator_sa}"
}

# 讓每個客戶的 deployer SA 都能從管理 Project 的 Artifact Registry pull 公版 image
resource "google_artifact_registry_repository_iam_member" "ar_reader" {
  for_each   = local.customers_by_id
  project    = var.mgmt_project_id
  location   = var.mgmt_region
  repository = var.artifact_registry_repo
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

# 實測發現：真正在 Cloud Run 建立 Revision 時去 pull image 的身分，
# 是每個客戶 Project 自己的 Cloud Run Service Agent（不是 deployer SA），
# 且這個 pull 動作是跨 Project 的（image 存在管理 Project），一樣需要明確授權。
# 少這個會在 skaffold apply 階段出現：
# "... must have permission to read the image ... artifactregistry.repositories.downloadArtifacts"
resource "google_artifact_registry_repository_iam_member" "run_agent_ar_reader" {
  for_each   = local.customers_by_id
  project    = var.mgmt_project_id
  location   = var.mgmt_region
  repository = var.artifact_registry_repo
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:service-${data.google_project.customer[each.key].number}@serverless-robot-prod.iam.gserviceaccount.com"
}

# deployer SA 需要能寫入自己 Cloud Build render/deploy 執行時的 log
# 少這個不會直接讓部署失敗，但 build log 會缺失，難以除錯
resource "google_project_iam_member" "log_writer" {
  for_each = local.customers_by_id
  project  = each.value.project_id
  role     = "roles/logging.logWriter"
  member   = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

# Cloud Deploy 用來存放「渲染後 manifest」的內部 bucket，名稱可預測
# （<region>.deploy-artifacts.<mgmt-project>.appspot.com）。deployer SA 的
# RENDER 階段要「寫入」渲染結果、DEPLOY 階段要「讀出」渲染結果，故用 objectAdmin。
# 注意：這個 bucket 是 Cloud Run/App Engine 相關 API 啟用後才會延遲建立，
# 若在管理 Project 從未啟用過 run.googleapis.com、也從未跑過任何 Cloud Deploy
# release，這個 bucket 可能還不存在，導致這個資源在第一次 apply 時失敗；
# 遇到這種情況，先手動觸發一次 Cloud Deploy release（即使會因權限失敗也沒關係，
# 失敗過程會把 bucket 建出來），再重跑 terraform apply 即可。
resource "google_storage_bucket_iam_member" "deploy_artifacts_admin" {
  for_each = local.customers_by_id
  bucket   = "${var.mgmt_region}.deploy-artifacts.${var.mgmt_project_id}.appspot.com"
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${google_service_account.deployer[each.key].email}"
}

# Cloud Deploy 的「原始碼上傳」暫存 bucket 命名是一組 hash（例如
# <hash>_clouddeploy），無法在 Target/Pipeline 建立前預先推算，因此無法放進
# 這份 Terraform（沒有穩定的資源位址可以參照）。第一次建置時，請在
# `gcloud deploy apply` 過至少一次 release 之後，執行
# approach-a-cloud-deploy/scripts/grant-clouddeploy-source-bucket-access.sh
# 補上 deployer SA 對這個 bucket 的讀取權限。


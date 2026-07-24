variable "mgmt_project_id" {
  description = "管理 Project ID（Cloud Deploy pipeline / Artifact Registry / 動態 fan-out 的 Cloud Build 都在這裡）"
  type        = string
}

variable "mgmt_region" {
  description = "Artifact Registry 所在 region"
  type        = string
  default     = "asia-east1"
}

variable "artifact_registry_repo" {
  description = "存放公版網站 image 的 Artifact Registry repo 名稱"
  type        = string
  default     = "demo-site"
}

variable "fanout_orchestrator_sa" {
  description = "方案 B 動態 fan-out 用的 Cloud Build 執行身分 email（用來 impersonate 各客戶的 deployer SA）"
  type        = string
  default     = "fanout-deployer@gcpdeploy-poc-mgmt.iam.gserviceaccount.com"
}

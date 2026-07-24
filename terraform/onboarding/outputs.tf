output "deployer_service_accounts" {
  description = "每個客戶 Project 對應的 deployer SA email，新增客戶後可用這個確認是否已產生"
  value       = { for id, sa in google_service_account.deployer : id => sa.email }
}

output "customer_count" {
  description = "目前 customers.yaml 註冊的客戶數量"
  value       = length(local.customers_by_id)
}

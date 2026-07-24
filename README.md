# GCP 多租戶 Demo 網站 —— 一次更新多個客戶 Project 的 PoC

## 情境

一個管理 Project（`mgmt-project`）+ N 個客戶 Project，每個客戶 Project 各自用 Cloud Run
跑同一份公版 Demo 網站（程式碼相同，內容依客戶不同）。目前 3 個客戶，未來會持續新增，
可能到 100+ 個。目標：改一次程式碼，能一口氣更新所有客戶的網站。

`customers.yaml`（放在本目錄根層）是**兩個方案共用的唯一資料來源**：新增客戶時，
只需要在這裡加一筆，不需要改任何部署設定本身。

## 目錄結構

```
customers.yaml                     # 客戶清單（單一資料來源）
terraform/onboarding/              # 共用：客戶 onboarding 時的跨 Project IAM 設定
approach-a-cloud-deploy/           # 方案 A：Cloud Deploy 平行部署
approach-b-dynamic-fanout/         # 方案 B：Cloud Build 動態 fan-out
```

## 前置準備（兩方案共用）

1. 在管理 Project 建 Artifact Registry repo 放公版 image。
2. 若組織有 `iam.disableCrossProjectServiceAccountUsage` 這條 Org Policy（預設通常是
   強制啟用），需要對管理 Project + 所有客戶 Project 開例外，否則 Cloud Deploy /
   Cloud Build 無法跨 Project 使用 deployer SA。這是組織安全政策，開例外前務必跟
   對應的 Org Admin / 資安負責人確認範圍（實務上建議只對相關 Project 開，不要開
   整個組織）。
3. 套用 `terraform/onboarding`：每新增一個客戶，這裡會自動幫該客戶 Project 建立一個
   專屬 `deployer` service account，並設好：
   - 該 SA 在自己 Project 內的 `roles/run.developer` / `roles/iam.serviceAccountUser` /
     `roles/logging.logWriter`
   - 讓管理 Project 能跨 Project 使用這個 SA（方案 A 用 Cloud Deploy service agent，
     方案 B 用自訂的 `fanout-deployer` SA）
   - 該 SA 對管理 Project Artifact Registry 的 `roles/artifactregistry.reader`
   - 該客戶 Project 的 **Cloud Run Service Agent**（`service-<number>@serverless-robot-prod...`，
     不是 deployer SA）對管理 Project Artifact Registry 的 `roles/artifactregistry.reader`
     —— 這是實測發現的關鍵：Cloud Run 建立 Revision 時真正去 pull image 的身分是
     這個 Service Agent，不是 deployer SA
   - deployer SA 對 Cloud Deploy 內部 `<region>.deploy-artifacts.<mgmt-project>.appspot.com`
     bucket 的 `roles/storage.objectAdmin`（render 階段寫入、deploy 階段讀出渲染結果）

   ```bash
   cd terraform/onboarding
   terraform init
   terraform apply -var="mgmt_project_id=mgmt-project"
   ```

   新增客戶時：改 `customers.yaml` → 重新 `terraform apply` 即可，套用範圍只會是
   新增的那幾筆（既有客戶的資源不受影響）。

4. **第一次**在全新管理 Project 建置時，Cloud Deploy 用來暫存原始碼的 bucket
   （命名是 `<hash>_clouddeploy`，hash 無法預先推算，故不在 Terraform 管理範圍內）
   要等 `gcloud deploy apply` 過 pipeline、且嘗試觸發過一次 release 之後才會被建出來。
   跑完第一次（即使失敗）之後，執行：
   ```bash
   ./approach-a-cloud-deploy/scripts/grant-clouddeploy-source-bucket-access.sh <mgmt_project_id>
   ```
   幫所有客戶的 deployer SA 補上這個 bucket 的讀取權限，再重新觸發一次 release。
5. Demo 網站通常要公開展示，部署完後執行：
   ```bash
   ./approach-a-cloud-deploy/scripts/make-services-public.sh
   ```
   幫所有客戶的 Cloud Run service 開放 `allUsers` 呼叫（預設新建立的 service 不開放，
   否則會看到 403）。

## 方案 A：Cloud Deploy 平行部署

適合：需要 rollout 歷史、審批關卡、per-target 回滾等治理能力。

**一次性設定**（新增/變更客戶時才需要重跑）：

```bash
cd approach-a-cloud-deploy
./scripts/generate-clouddeploy-config.sh          # 讀 customers.yaml 產生 Target + multiTarget
gcloud deploy apply --file=clouddeploy.generated.yaml --region=asia-east1 --project=mgmt-project
```

**日常觸發部署**（改完程式碼、想要一次更新所有客戶網站時）：

```bash
./deploy.sh   # 在專案根目錄執行：build image → push → 建立 Release → 平行 rollout
```

`deploy.sh` 內部做兩件事，也可以拆開手動跑：

```bash
# 1. Build + push image（用 commit hash 或任何字串當 tag 都可以）
gcloud builds submit --project=gcpdeploy-poc-mgmt \
  --tag=asia-east1-docker.pkg.dev/gcpdeploy-poc-mgmt/demo-site/app:$(git rev-parse --short HEAD) .

# 2. 建立 Release，觸發對所有客戶的平行部署
./approach-a-cloud-deploy/scripts/create-release.sh $(git rev-parse --short HEAD)
```

跑完之後查看 rollout 狀態：
```bash
gcloud deploy rollouts list --release=<release-name> --delivery-pipeline=demo-site-pipeline \
  --project=gcpdeploy-poc-mgmt --region=asia-east1
```

> 目前是「手動觸發」模式（你自己執行 `./deploy.sh`）。如果之後想要「git push 自動觸發」，
> 需要把這個目錄接到 Cloud Source Repositories 或 GitHub，建一個 Cloud Build Trigger，
> 把 `deploy.sh` 的邏輯放進 `cloudbuild.yaml` 讓 push 事件自動呼叫；目前這份 PoC 還沒
> 接上這一層，是刻意先驗證核心部署邏輯本身。

- 新增客戶：`customers.yaml` 加一筆 → 重跑 `generate-clouddeploy-config.sh` → 重新
  `gcloud deploy apply`，新客戶就會自動加進 `all-customers` 這個 multiTarget。
- 平行度受 Cloud Build 併發 quota 限制，100+ 客戶建議申請提高併發數或改用 Private Pool。
- `run-service.yaml` 用 Cloud Deploy 官方的 `# from-param: ${customer-id}` 語法，
  依 Target 的 `deployParameters.customer-id` 自動代換，做到「同一份 manifest、不同客戶內容」。

## 方案 B：動態 Fan-out（Cloud Build）

適合：客戶數量會持續快速成長、不需要每個客戶獨立審批/回滾介面，希望新增客戶時
完全不用碰部署設定。

```bash
cd approach-b-dynamic-fanout
gcloud builds submit --config=cloudbuild.yaml ..
```

- `scripts/deploy-fanout.sh` 執行期動態讀 `customers.yaml`，用 bash job control
  控制併發數（預設 10，可調），逐一 impersonate 各客戶的 deployer SA 執行
  `gcloud run deploy`。
- 新增客戶：`customers.yaml` 加一筆即可，完全不用改 `cloudbuild.yaml` 或任何
  部署設定。
- 沒有 Cloud Deploy 的 rollout 歷史/審批/回滾 UI，失敗與成功清單只會印在 build log，
  需要更嚴謹的稽核或回滾機制要自己另外做。

## 兩方案比較

| | 方案 A：Cloud Deploy | 方案 B：動態 Fan-out |
|---|---|---|
| 新增客戶時要做的事 | `customers.yaml` +1 → 重跑產生腳本 → `gcloud deploy apply` | `customers.yaml` +1，其他都不用動 |
| Rollout 歷史 / 回滾 UI | 有，per-target | 沒有，需自建 |
| 審批關卡（Canary / Approval） | 支援 | 需自建 |
| 100+ 客戶時的維護負擔 | 中（多一份要 apply 的產生設定） | 低（腳本讀清單即時展開） |
| 平行度瓶頸 | Cloud Build 併發 quota | Cloud Build 併發 quota（同樣） |
| 適合情境 | 需要向客戶/內部證明有正式治理流程 | 純粹追求「改一次、全部更新」的效率 |

## 實測踩過的坑（方案 A，2026-07-15 在真實 GCP 環境跑通）

這份 PoC 曾經在全新的管理 Project + 3 個全新客戶 Project 上，從零建置到「一次 Release
平行部署、3 個客戶各自顯示正確內容」全部跑通。過程中依序踩到以下真實環境才會出現的問題，
已全部折進 `terraform/onboarding` 或對應腳本，未來新客戶 onboarding 不需要再手動修：

1. **Billing Account 有「可連結 Project 數」配額上限**——新建 Project 時若 billing
   account 已連到太多 Project，`gcloud billing projects link` 會直接報 quota 錯誤。
2. **Cloud Build 用的預設 Compute SA 需要手動授權**兩個地方：對 Cloud Build 自動建立的
   `<project>_cloudbuild` staging bucket要有 `storage.objectViewer`；對目標 Artifact
   Registry repo 要有 `roles/artifactregistry.writer`。新專案這兩個預設不會自動授權好。
3. **`iam.disableCrossProjectServiceAccountUsage` Org Policy**：只要「Cloud Deploy
   Pipeline/Target 定義在管理 Project」而「執行用的 SA 在客戶 Project」，這個組合本身
   就算「跨 Project 使用 SA」，會被這條政策擋下來，跟 SA 本來屬於誰無關。需要對相關
   Project 開例外（`enforced: false`）。
4. **Cloud Deploy 兩個內部 bucket 都要授權，而且讀寫方向不同**：
   - `<region>.deploy-artifacts.<mgmt-project>.appspot.com`：deployer SA 的 RENDER
     階段要「寫入」渲染結果、DEPLOY 階段要「讀出」，兩階段用同一顆 SA，故需要
     `roles/storage.objectAdmin`（只給 read 會讓 render 表面上「成功」但其實沒真的
     寫入任何東西，deploy 階段才會爆 object not found）。
   - `<hash>_clouddeploy`（原始碼上傳暫存）：deployer SA 需要 `storage.objectViewer`。
     這個 bucket 名稱含隨機 hash，第一次建置前無法預測，只能等 pipeline 跑過一次
     release 之後才能查到、補權限。
5. **deployer SA 需要 `roles/logging.logWriter`**，不然不會讓部署失敗，但 build log
   會缺失、之後除錯會很痛苦。
6. **（最關鍵、最不直覺的一個）Cloud Run 的 Service Agent 才是真正 pull image 的身分**：
   `service-<customer-project-number>@serverless-robot-prod.iam.gserviceaccount.com`，
   不是 deployer SA。這個 Service Agent 需要對管理 Project 的 Artifact Registry repo
   有 `roles/artifactregistry.reader`，否則 revision 會卡在 `failed`，錯誤訊息會明確
   點名這個 Service Agent 帳號。
7. 新建立的 Cloud Run service 預設不開放未驗證存取，公開 Demo 網站要另外
   `gcloud run services add-iam-policy-binding --member=allUsers --role=roles/run.invoker`。
8. 多數 IAM 變更（尤其是 Org Policy、跨 Project SA 綁定）有數十秒到數分鐘的傳播延遲，
   遇到剛授權完還是報同一個權限錯誤，先等一下再重試，不代表授權本身下錯。

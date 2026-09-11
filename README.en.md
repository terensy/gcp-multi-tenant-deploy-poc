[繁體中文](README.md) | **English**

# GCP Multi-Tenant Demo Site — PoC for Updating Multiple Customer Projects in One Go

## Scenario

One management project (`mgmt-project`) plus N customer projects, each running the same standard demo site (identical code, different content per customer) on Cloud Run. Currently three customers, with more to be added over time — potentially 100+. Goal: change the code once and update all customer sites simultaneously.

`customers.yaml` (in the root of this directory) is the **single source of truth shared by both approaches**: to add a customer, add one entry here — no deployment configuration needs to change.

## Directory Structure

```
customers.yaml                     # Customer list (single source of truth)
terraform/onboarding/              # Shared: cross-project IAM setup for customer onboarding
approach-a-cloud-deploy/           # Approach A: Cloud Deploy parallel deployment
approach-b-dynamic-fanout/         # Approach B: Cloud Build dynamic fan-out
```

## Prerequisites (shared by both approaches)

1. Create an Artifact Registry repository in the management project to host the standard image.
2. If your organisation has the `iam.disableCrossProjectServiceAccountUsage` org policy enabled (the default in most organisations), you will need to add exceptions for the management project and all customer projects; otherwise Cloud Deploy / Cloud Build cannot use the deployer service account across projects. This is an organisational security policy — confirm the scope with your Org Admin or security team before granting exceptions (in practice, apply exceptions only to the relevant projects, not the entire organisation).
3. Apply `terraform/onboarding`: each time a new customer is added, this automatically creates a dedicated `deployer` service account for that customer project and configures:
   - `roles/run.developer` / `roles/iam.serviceAccountUser` / `roles/logging.logWriter` for the SA within its own project
   - Cross-project permission allowing the management project to use this SA (Approach A uses the Cloud Deploy service agent; Approach B uses a custom `fanout-deployer` SA)
   - `roles/artifactregistry.reader` on the management project's Artifact Registry for the SA
   - `roles/artifactregistry.reader` on the management project's Artifact Registry for that customer project's **Cloud Run Service Agent** (`service-<number>@serverless-robot-prod...`, not the deployer SA) — this is a key finding from real testing: the identity that actually pulls the image when Cloud Run creates a Revision is this Service Agent, not the deployer SA
   - `roles/storage.objectAdmin` on the Cloud Deploy internal bucket `<region>.deploy-artifacts.<mgmt-project>.appspot.com` for the deployer SA (written during render, read during deploy — both stages use the same SA, so objectAdmin is needed; giving only read permission makes render appear to "succeed" but nothing is actually written, causing an object-not-found error at deploy time)

   ```bash
   cd terraform/onboarding
   terraform init
   terraform apply -var="mgmt_project_id=mgmt-project"
   ```

   To add a new customer: update `customers.yaml` → re-run `terraform apply`. Only the new entries are affected; existing customer resources are untouched.

4. **The first time** you set up a brand-new management project, the Cloud Deploy staging bucket (named `<hash>_clouddeploy` — the hash cannot be predicted in advance and is therefore outside Terraform's scope) is not created until after `gcloud deploy apply` has run the pipeline and a release has been triggered at least once. Once that first run is complete (even if it fails), run:
   ```bash
   ./approach-a-cloud-deploy/scripts/grant-clouddeploy-source-bucket-access.sh <mgmt_project_id>
   ```
   to grant all customer deployer SAs read access to this bucket, then trigger a release again.
5. Demo sites are typically publicly accessible. After deployment, run:
   ```bash
   ./approach-a-cloud-deploy/scripts/make-services-public.sh
   ```
   to add an `allUsers` invoker binding to all customer Cloud Run services (by default, newly created services do not allow unauthenticated access, which results in 403 errors).

## Approach A: Cloud Deploy Parallel Deployment

Suited for: when you need rollout history, approval gates, per-target rollback, and other governance capabilities.

**One-time setup** (only needed when adding or changing customers):

```bash
cd approach-a-cloud-deploy
./scripts/generate-clouddeploy-config.sh          # Reads customers.yaml and generates Targets + multiTarget
gcloud deploy apply --file=clouddeploy.generated.yaml --region=asia-east1 --project=mgmt-project
```

**Day-to-day deployment trigger** (after changing the code and wanting to update all customer sites at once):

```bash
./deploy.sh   # Run from the project root: build image → push → create Release → parallel rollout
```

`deploy.sh` does two things internally, which can also be run separately:

```bash
# 1. Build and push image (commit hash or any string can be used as the tag)
gcloud builds submit --project=gcpdeploy-poc-mgmt \
  --tag=asia-east1-docker.pkg.dev/gcpdeploy-poc-mgmt/demo-site/app:$(git rev-parse --short HEAD) .

# 2. Create a Release to trigger parallel deployment to all customers
./approach-a-cloud-deploy/scripts/create-release.sh $(git rev-parse --short HEAD)
```

Check rollout status after running:
```bash
gcloud deploy rollouts list --release=<release-name> --delivery-pipeline=demo-site-pipeline \
  --project=gcpdeploy-poc-mgmt --region=asia-east1
```

> This is currently a "manual trigger" model (you run `./deploy.sh` yourself). If you later want "git push triggers automatically", you would need to connect this directory to Cloud Source Repositories or GitHub, create a Cloud Build Trigger, and put the `deploy.sh` logic into a `cloudbuild.yaml` so that push events invoke it automatically. This PoC deliberately does not include that layer yet — the goal was to validate the core deployment logic first.

- To add a customer: add an entry to `customers.yaml` → re-run `generate-clouddeploy-config.sh` → re-apply `gcloud deploy apply`. The new customer is automatically added to the `all-customers` multiTarget.
- Parallelism is limited by Cloud Build concurrency quota. For 100+ customers, consider requesting a higher concurrency limit or switching to a Private Pool.
- `run-service.yaml` uses Cloud Deploy's official `# from-param: ${customer-id}` syntax to substitute values based on each Target's `deployParameters.customer-id`, achieving "one manifest, different content per customer".

## Approach B: Dynamic Fan-out (Cloud Build)

Suited for: when the customer count will grow rapidly and continuously, no per-customer approval/rollback UI is required, and you want adding a new customer to require zero changes to deployment configuration.

```bash
cd approach-b-dynamic-fanout
gcloud builds submit --config=cloudbuild.yaml ..
```

- `scripts/deploy-fanout.sh` reads `customers.yaml` at runtime and uses bash job control to manage concurrency (default 10, configurable), impersonating each customer's deployer SA in turn to run `gcloud run deploy`.
- To add a customer: add an entry to `customers.yaml` — no changes to `cloudbuild.yaml` or any deployment configuration are needed.
- There is no Cloud Deploy rollout history, approval UI, or rollback UI. Success and failure summaries are printed only in the build log. If you need stricter auditing or rollback capability, you will need to build that yourself.

## Comparison of Both Approaches

| | Approach A: Cloud Deploy | Approach B: Dynamic Fan-out |
|---|---|---|
| What you do to add a customer | `customers.yaml` +1 → re-run generation script → `gcloud deploy apply` | `customers.yaml` +1, nothing else |
| Rollout history / rollback UI | Yes, per-target | No — must build your own |
| Approval gates (canary / approval) | Supported | Must build your own |
| Maintenance overhead at 100+ customers | Medium (an extra generated config to apply) | Low (script expands the list at runtime) |
| Parallelism bottleneck | Cloud Build concurrency quota | Cloud Build concurrency quota (same) |
| Best suited for | Demonstrating formal governance processes to customers or internal stakeholders | Pure efficiency — change once, update everything |

## Real Pitfalls Encountered (Approach A, validated in a real GCP environment on 2026-07-15)

This PoC was built from scratch in a brand-new management project plus three brand-new customer projects, taken all the way from zero to "one Release, three customers each showing correct content in parallel". The following real-environment issues were encountered along the way and have all been addressed in `terraform/onboarding` or the corresponding scripts — new customer onboarding will not require manual intervention for any of these:

1. **Billing Account has a quota limit on the number of linked projects** — when creating a new project, if the billing account is already linked to too many projects, `gcloud billing projects link` fails immediately with a quota error.
2. **The default Compute SA used by Cloud Build requires manual authorisation** in two places: `storage.objectViewer` on the `<project>_cloudbuild` staging bucket Cloud Build creates automatically, and `roles/artifactregistry.writer` on the target Artifact Registry repository. Neither is granted automatically for a new project.
3. **`iam.disableCrossProjectServiceAccountUsage` org policy**: simply having the Cloud Deploy Pipeline/Target defined in the management project whilst the execution SA is in a customer project is itself classified as "cross-project SA use", and is blocked by this policy regardless of which project owns the SA. Exceptions (`enforced: false`) are required for the relevant projects.
4. **Both Cloud Deploy internal buckets require authorisation, and the access directions differ**:
   - `<region>.deploy-artifacts.<mgmt-project>.appspot.com`: the deployer SA must **write** during render and **read** during deploy — both stages use the same SA, so `roles/storage.objectAdmin` is needed. Granting only read access makes render appear to succeed but nothing is actually written, causing an object-not-found error at deploy time.
   - `<hash>_clouddeploy` (source upload staging): the deployer SA needs `storage.objectViewer`. The bucket name contains a random hash that cannot be predicted before the first build — you can only look it up and grant access after the pipeline has run a release at least once.
5. **The deployer SA needs `roles/logging.logWriter`** — its absence does not cause deployment to fail, but build log entries will be missing, making later debugging very painful.
6. **(The most critical and least intuitive finding) The Cloud Run Service Agent is the identity that actually pulls the image**: `service-<customer-project-number>@serverless-robot-prod.iam.gserviceaccount.com`, not the deployer SA. This Service Agent needs `roles/artifactregistry.reader` on the management project's Artifact Registry repository; without it, the revision gets stuck in `failed` and the error message explicitly names this Service Agent account.
7. Newly created Cloud Run services do not allow unauthenticated access by default. For a public demo site, you need to separately run `gcloud run services add-iam-policy-binding --member=allUsers --role=roles/run.invoker`.
8. Most IAM changes (especially org policy updates and cross-project SA bindings) have a propagation delay of tens of seconds to a few minutes. If you get the same permission error immediately after granting access, wait a moment and retry — it does not necessarily mean the grant was incorrect.

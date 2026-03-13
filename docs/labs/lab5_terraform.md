# Lab 5 — Terraform & Infrastructure as Code

**Prereqs:** Docker stack running. Terraform CLI installed (`brew install terraform`). AWS CLI installed (`brew install awscli`).
**Time:** 45 minutes
**Goal:** Understand Infrastructure as Code, provision resources with Terraform, interact with S3 via AWS CLI.

---

## Why This Matters

On the job, you'll use Terraform to provision AWS resources: S3 buckets for payload storage, VPCs for network segmentation, EKS clusters for container orchestration. You never click through the AWS console to create production resources — everything is code, versioned in Git, reviewed in PRs.

LocalStack simulates AWS locally so you can learn Terraform patterns without spending money.

---

## Part A — Read the Config (10 min)

### Task A1: Understand the Terraform files
Open and read each file in `infra/terraform/`:

```bash
cat infra/terraform/main.tf
cat infra/terraform/variables.tf
cat infra/terraform/outputs.tf
```

**Questions to answer:**
1. What provider is configured? What makes it point to LocalStack instead of real AWS?
2. How many S3 buckets are created? What is each one for?
3. What does `skip_credentials_validation = true` do and why is it needed?
4. What is a Terraform variable? How does `var.aws_region` get its value?
5. What is a Terraform output? Why would you use one?

### Task A2: Understand the state concept
Terraform tracks what it has created in a **state file** (`terraform.tfstate`). This file maps your `.tf` config to real resources. Without it, Terraform doesn't know what exists.

**Question:** What happens if you delete `terraform.tfstate` and run `terraform apply` again? (Answer: Terraform thinks nothing exists and tries to create everything from scratch — duplicating resources.)

---

## Part B — Apply the Config (10 min)

### Task B1: Initialise Terraform
```bash
cd infra/terraform
terraform init
```

**Expected output:** "Terraform has been successfully initialized!" This downloads the AWS provider plugin.

### Task B2: Plan (dry run)
```bash
terraform plan
```

Read the output carefully. It shows what Terraform **would** create without actually creating it.

**Questions:**
- How many resources will be created?
- Can you identify which resource is the S3 bucket vs the lifecycle rule vs versioning?

### Task B3: Apply (create the resources)
```bash
terraform apply -auto-approve
```

**Expected:** "Apply complete! Resources: X added, 0 changed, 0 destroyed." Plus the outputs showing bucket names.

### Task B4: Verify with AWS CLI
```bash
# List all S3 buckets in LocalStack
aws --endpoint-url=http://localhost:4566 s3 ls

# Check versioning on audit bucket
aws --endpoint-url=http://localhost:4566 s3api get-bucket-versioning --bucket etrm-audit
```

**Expected:** 3 buckets listed. Audit bucket shows versioning enabled.

---

## Part C — Use S3 (10 min)

### Task C1: Upload a test file
```bash
# Create a test trade payload
echo '{"trade_id": 1, "unique_id": "TRADE-JP-001", "status": "active"}' > /tmp/trade_payload.json

# Upload to the payloads bucket
aws --endpoint-url=http://localhost:4566 s3 cp /tmp/trade_payload.json s3://etrm-payloads/trades/2025/01/trade-001.json

# Verify it's there
aws --endpoint-url=http://localhost:4566 s3 ls s3://etrm-payloads/trades/2025/01/
```

### Task C2: Download it back
```bash
aws --endpoint-url=http://localhost:4566 s3 cp s3://etrm-payloads/trades/2025/01/trade-001.json /tmp/downloaded_trade.json
cat /tmp/downloaded_trade.json
```

### Task C3: Upload a curve snapshot
```bash
# Simulate saving an MTM curve snapshot to S3
echo '{"curve_id": 1, "area": "JEPX", "date": "2025-01-15", "prices": [11.2, 11.5, 11.8]}' > /tmp/curve_snapshot.json

aws --endpoint-url=http://localhost:4566 s3 cp /tmp/curve_snapshot.json s3://etrm-curves/jepx/2025-01-15.json

# List the curves bucket
aws --endpoint-url=http://localhost:4566 s3 ls s3://etrm-curves/ --recursive
```

**Question:** On the job, why would you store curve snapshots in S3 instead of the database? (Answer: Curves are large, versioned daily, and rarely re-queried. S3 is cheaper than database storage. ClickHouse stores the active curve; S3 archives the history.)

---

## Part D — Modify and Re-Apply (10 min)

### Task D1: Add a new S3 bucket
Open `infra/terraform/main.tf` and add at the bottom:

```hcl
resource "aws_s3_bucket" "reports" {
  bucket = "etrm-reports"
  tags = {
    Environment = "sandbox"
    Purpose     = "Generated reports and dashboards"
  }
}
```

### Task D2: Plan the change
```bash
terraform plan
```

**Expected:** "1 to add, 0 to change, 0 to destroy." Terraform only creates the new bucket — it doesn't touch the existing ones.

### Task D3: Apply it
```bash
terraform apply -auto-approve
```

### Task D4: Verify
```bash
aws --endpoint-url=http://localhost:4566 s3 ls
```

**Expected:** 4 buckets now.

### Task D5: Destroy a resource
Remove the `reports` bucket block you just added from `main.tf`, then:
```bash
terraform plan    # shows "1 to destroy"
terraform apply -auto-approve
```

**Expected:** Back to 3 buckets. Terraform destroyed only the resource you removed from config.

---

## Part E — Inspect State (5 min)

### Task E1: List what Terraform manages
```bash
terraform state list
```

This shows every resource Terraform tracks. Each one maps to a block in your `.tf` files.

### Task E2: Show details of a specific resource
```bash
terraform state show aws_s3_bucket.payloads
```

This shows the full attributes of the bucket as Terraform sees it.

### Task E3: Understand the state file
```bash
cat terraform.tfstate | head -50
```

This is JSON. In production, this file is stored remotely (S3 + DynamoDB for locking) so the team shares state. Never commit it to Git.

---

## Part F — State Drift: The #1 IaC Problem (10 min)

State drift happens when someone changes infrastructure manually (via console or CLI) without updating Terraform. This is the most common real-world IaC issue.

### Task F1: Create drift intentionally

```bash
# Create a bucket manually via AWS CLI — Terraform doesn't know about it
aws --endpoint-url=http://localhost:4566 s3 mb s3://etrm-rogue-bucket
```

Now run:
```bash
terraform plan
```

**Observation:** Terraform says "No changes." It doesn't know about `etrm-rogue-bucket` because it's not in the state file. This bucket is *invisible* to Terraform — it exists in AWS but not in code. This is drift.

### Task F2: Understand why drift is dangerous

In production:
- Someone creates a security group via the AWS console to unblock themselves
- It has `0.0.0.0/0` ingress (open to the internet)
- Terraform doesn't know about it, so no one reviews it
- 3 months later, an attacker discovers it

**The rule:** Never create infrastructure outside of Terraform. If you must make an emergency change, immediately add it to Terraform (`terraform import`) so it's tracked.

### Task F3: Import a drifted resource

Add this block to `main.tf`:
```hcl
resource "aws_s3_bucket" "rogue" {
  bucket = "etrm-rogue-bucket"
}
```

Then import it:
```bash
terraform import aws_s3_bucket.rogue etrm-rogue-bucket
terraform plan  # should now show "No changes"
```

Clean up — remove the `rogue` block from `main.tf`, then:
```bash
terraform apply -auto-approve
```

---

## Checkpoint: What You Should Be Able to Do

- [ ] Explain what Infrastructure as Code means and why firms use it
- [ ] Read a Terraform config and identify providers, resources, variables, outputs
- [ ] Run `terraform init`, `plan`, `apply`, and explain what each does
- [ ] Add a new resource, plan the change, apply it
- [ ] Remove a resource and apply to destroy it
- [ ] Use AWS CLI to interact with S3 buckets (upload, download, list)
- [ ] Explain what `terraform.tfstate` is and why it matters
- [ ] Explain what state drift is and why it's dangerous
- [ ] Use `terraform import` to adopt a manually-created resource

---

## Reflection Questions

1. **In production:** Your team uses Terraform to manage 50 S3 buckets, 3 VPCs, and an EKS cluster. A junior engineer manually creates an S3 bucket via the AWS console. What happens when you run `terraform apply`? (Answer: Terraform doesn't know about it — it's not in state. It won't manage or delete it, but it also won't show up in `terraform state list`. This is called "drift." You saw this in Part F.)

2. **On the job:** Someone asks you to add a new S3 bucket for compliance logs with 7-year retention. How would you do it? (Answer: Add a `aws_s3_bucket` + `aws_s3_bucket_lifecycle_configuration` resource to the Terraform config, set expiration to 2555 days, open a PR for review, merge, let CI/CD apply it.)

3. **Why LocalStack?** What are the limitations of LocalStack free tier vs real AWS? (Answer: Free tier only supports S3, SQS, SNS, Lambda, and a few others. VPC, EKS, RDS, and IAM policies require LocalStack Pro or real AWS.)

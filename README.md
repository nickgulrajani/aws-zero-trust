# Zero Trust AWS Architecture — Dry Run (No Costs)

This repository demonstrates **Zero Trust security** patterns on AWS using **Terraform** and **GitHub Actions** — **no AWS API calls** and **no charges**.

### Features
- **Network isolation**: VPC with **private subnets only** (no IGW).
- **Private connectivity**: Interface **VPC Endpoints** via **AWS PrivateLink** for S3, KMS, and Secrets Manager.
- **IAM least privilege**: App role scoped to one bucket + one KMS key.
- **Encryption**: KMS CMK with rotation enabled.
- **Guardrails**: SCP example denies usage outside `us-east-1`.
- **S3 Bucket** locked to **PrivateLink** via `aws:sourceVpce`.

### Safe Dry Run
- Terraform uses: `-backend=false`, `-refresh=false`, `skip_credentials_validation`, `skip_requesting_account_id`.
- GitHub Actions never executes `apply`, only `plan`.

### Quickstart
```bash
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate

terraform -chdir=terraform plan -refresh=false   -var-file=../tfvars/minimal.tfvars   -out=tfplan.binary

terraform -chdir=terraform show -json tfplan.binary > tfplan.json
```

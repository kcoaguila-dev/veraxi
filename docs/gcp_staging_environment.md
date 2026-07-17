# GCP Staging Environment Setup

This document outlines how to spin up a persistent Google Cloud Platform (GCP) Virtual Machine specifically for staging and testing the Veraxi application.

This approach allows you to code locally on your primary development machine, but push the code to a high-RAM cloud environment to run the heavy components (Neo4j, Qdrant, and LLM integrations) without bogging down your local system.

## 1. VM Specifications

**Why Google's Container-Optimized OS (COS)?**
Because Jules fully Dockerized the Veraxi stack in Phase 8 (including the FastAPI backend), we no longer need to run Python natively on the host machine. This allows us to use Google's Container-Optimized OS (COS). COS is a highly secure, incredibly lightweight OS purpose-built by Google *exclusively* for running Docker containers. It has no package manager and a read-only root filesystem, meaning it is virtually impervious to standard Linux malware and boots incredibly fast.

- **Machine Type:** `e2-standard-4` (4 vCPU, 16GB RAM). *Neo4j and Qdrant are highly memory-intensive. 16GB provides enough headroom for the databases plus the Python backend.*
- **OS Image:** `cos-stable` (Container-Optimized OS).
- **Disk:** 30GB Standard Persistent Disk.

## 2. One-Time VM Creation

You have two options for creating the VM depending on your preference:

### Option A: Quick CLI (Recommended for beginners)
Run this command from your local machine (where `gcloud` is authenticated) or from Google Cloud Shell:

```bash
gcloud compute instances create veraxi-staging \
  --machine-type=e2-standard-4 \
  --image-family=cos-stable \
  --image-project=cos-cloud \
  --boot-disk-size=30GB \
  --tags=http-server,https-server
```

### Option B: Terraform (Recommended for teams)
We use **Terraform** (Infrastructure as Code) to provision this VM so that our staging environment is perfectly reproducible.

1. Navigate to the `infra/` directory:
   ```bash
   cd infra
   ```
2. Create a file named `terraform.tfvars` (this file is ignored by git so your project ID stays private) and add your project ID:
   ```hcl
   project_id = "your-actual-gcp-project-id"
   ```
3. Initialize and apply the Terraform configuration:
   ```bash
   terraform init
   terraform apply
   ```
*(Terraform will show you what it plans to create. Type `yes` to confirm).*

## 3. Initial VM Setup

Because COS comes with Docker pre-installed out of the box, **there is zero initial setup required on the VM itself!** You do not need to install `docker`, `python`, or configure any virtual environments.

*(You can skip straight to the workflow step).*

## 4. The Sync-and-Test Workflow

Because you are writing code locally but testing in the cloud, do **not** use `git clone` on the VM. It will force you to commit unfinished code just to test it.

We have automated this sync process into the project's Makefile!

Whenever you want to test your local changes on GCP, simply run:
```bash
make test-gcp
```

*(Note: If you or another contributor want to use a different VM name, you can pass it directly to the underlying script like `./scripts/test_on_gcp.sh my-custom-vm`)*

This script will automatically:
1. Sync your current local directory to the GCP VM.
2. SSH into the VM and use Docker to spin up the databases and the FastAPI backend.
3. Run the entire `pytest` suite directly inside the backend container.

## 5. Cost Management: Stop, Don't Delete

To avoid losing your setup, do **not** delete the VM when you are done for the day. Instead, **stop** it. When a VM is stopped, you are only billed pennies for the disk storage, and you stop paying the hourly rate for the CPU/RAM.

**When you are done testing:**
```bash
gcloud compute instances stop veraxi-staging
```

**When you come back the next day:**
```bash
gcloud compute instances start veraxi-staging
# Everything will be exactly as you left it!
```

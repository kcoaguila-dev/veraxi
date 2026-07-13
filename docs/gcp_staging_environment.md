# GCP Staging Environment Setup

This document outlines how to spin up a persistent Google Cloud Platform (GCP) Virtual Machine specifically for staging and testing the Veraxi application. 

This approach allows you to code locally on your primary development machine, but push the code to a high-RAM cloud environment to run the heavy components (Neo4j, Qdrant, and LLM integrations) without bogging down your local system.

## 1. VM Specifications

**Why not Google's Container-Optimized OS (COS) or Alpine?**
While Google's Container-Optimized OS is incredibly lightweight and secure (it has no terminal shell/package manager by default), its root filesystem is read-only and it is designed *exclusively* for running Docker containers. Because our current Veraxi testing workflow requires running `pytest` in a local Python virtual environment (while only the databases are in Docker), a minimal Debian installation is the much better choice. It is still extremely lightweight (no GUI, minimal background processes) but allows you to easily run Python natively without complex workarounds.

- **Machine Type:** `e2-standard-4` (4 vCPU, 16GB RAM). *Neo4j and Qdrant are highly memory-intensive. 16GB provides enough headroom for the databases plus the Python backend.*
- **OS Image:** `debian-12` (Minimal, no GUI).
- **Disk:** 30GB Standard Persistent Disk.

## 2. One-Time VM Creation

Run this command from your local machine (where `gcloud` is authenticated) to create the VM:

```bash
gcloud compute instances create veraxi-staging \
  --machine-type=e2-standard-4 \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=30GB \
  --tags=http-server,https-server
```

## 3. Initial VM Setup (Run Once)

SSH into the new machine:
```bash
gcloud compute ssh veraxi-staging
```

Install Docker, Docker Compose, and Python tools:
```bash
# Update and install dependencies
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin python3-pip python3-venv git

# Allow your user to run Docker without sudo
sudo usermod -aG docker $USER
newgrp docker
```

*(You can now log out of the SSH session).*

## 4. The Sync-and-Test Workflow

Because you are writing code locally but testing in the cloud, do **not** use `git clone` on the VM. It will force you to commit unfinished code just to test it. 

We have created an automated bash script that syncs your local code to the VM (excluding massive build folders) and runs the test suite in one command!

Whenever you want to test your local changes on GCP, simply run:
```bash
./scripts/test_on_gcp.sh
```

*(Note: If you or another contributor want to use a different VM name, you can pass it directly as an argument like `./scripts/test_on_gcp.sh my-custom-vm`)*

This script will automatically:
1. Sync your current local directory to the GCP VM.
2. SSH into the VM and start the database containers.
3. Set up the Python virtual environment (if it doesn't exist).
4. Run the entire `pytest` suite.

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

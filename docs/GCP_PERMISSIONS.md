# GCP Permissions for OpenShift UPI Deployment

This document outlines the required GCP permissions and IAM roles for deploying OpenShift 4.19 UPI (User Provisioned Infrastructure) on Google Cloud Platform.

**Key Distinction: UPI deployment requires broader infrastructure permissions, while OpenShift cluster operations need limited, specific permissions for ongoing functionality.**

## Table of Contents

- [Overview: UPI vs OpenShift Permissions](#overview-upi-vs-openshift-permissions)
- [Prerequisites](#prerequisites)
- [Phase 1: UPI Deployment Permissions](#phase-1-upi-deployment-permissions)
- [Phase 2: OpenShift Cluster Operations](#phase-2-openshift-cluster-operations)
- [Service Account Setup](#service-account-setup)
- [Required API Services](#required-api-services)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting Permission Issues](#troubleshooting-permission-issues)

## Overview: UPI vs OpenShift Permissions

### UPI Deployment Phase (Temporary Broad Access)
**Purpose**: Create infrastructure (VMs, networks, DNS, storage)
**Duration**: Only during initial deployment
**Permissions**: Broad administrative access to create resources
**Scope**: Project-level permissions for infrastructure provisioning

### OpenShift Operations Phase (Limited Ongoing Access)
**Purpose**: Cluster functionality (storage, networking, monitoring)
**Duration**: Ongoing cluster operations
**Permissions**: Minimal required permissions for specific operations
**Scope**: Resource-specific permissions following least-privilege principle

---

## Prerequisites

Before starting, ensure you have:

- A GCP project with billing enabled
- gcloud CLI installed and configured
- Appropriate permissions to create IAM roles and service accounts

## Phase 1: UPI Deployment Permissions

### User Account for UPI Deployment

**IMPORTANT**: These permissions are needed ONLY during UPI deployment phase.

#### Option A: Owner Role (Simplest)
```bash
roles/owner    # Full project access - easiest but broadest
```

#### Option B: Minimal UPI Deployment Roles (Recommended)
```bash
# Infrastructure Management
roles/compute.admin                   # Create VMs, networks, disks, firewalls
roles/dns.admin                      # Create DNS zones and records
roles/storage.admin                  # Create GCS buckets for ignition files

# IAM Management  
roles/iam.serviceAccountAdmin        # Create service accounts
roles/iam.serviceAccountKeyAdmin     # Create service account keys
roles/resourcemanager.projectIamAdmin # Assign IAM policies

# API Management
roles/serviceusage.serviceUsageAdmin  # Enable required APIs
```

#### UPI Deployment Scope
These permissions are used for:
- Creating compute instances (bootstrap, control planes, workers, bastion)
- Setting up networking (VPC, subnets, firewall rules)
- Configuring DNS (private zones, A records)
- Creating storage (GCS buckets for ignition files)
- Setting up service accounts for ongoing operations

### Verify User Permissions

```bash
# Check current user permissions
gcloud auth list
gcloud config get-value project

# Test permissions
gcloud iam roles list --filter="name:roles/owner" --limit=1
gcloud services list --enabled
```

## Service Account Setup

### 1. Create Terraform Service Account

```bash
# Create service account for Terraform
gcloud iam service-accounts create openshift-terraform \
    --display-name="OpenShift Terraform Service Account" \
    --description="Service account for Terraform OpenShift UPI deployment"
```

### 2. Create OpenShift Node Service Account

```bash
# Create service account for OpenShift nodes
gcloud iam service-accounts create ocp-node-sa \
    --display-name="OpenShift Node Service Account" \
    --description="Service account for OpenShift cluster nodes"
```

## Required API Services

Enable the following APIs in your GCP project:

```bash
# Enable required APIs
gcloud services enable compute.googleapis.com
gcloud services enable dns.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable iamcredentials.googleapis.com
gcloud services enable serviceusage.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com

# Verify APIs are enabled
gcloud services list --enabled --filter="name:(compute.googleapis.com OR dns.googleapis.com OR storage.googleapis.com)"
```

### Terraform Service Account (UPI Deployment Only)

**TEMPORARY**: These permissions are only needed during UPI infrastructure deployment.

### Terraform Infrastructure Roles

```bash
PROJECT_ID=$(gcloud config get-value project)
TERRAFORM_SA="openshift-terraform@${PROJECT_ID}.iam.gserviceaccount.com"

# UPI DEPLOYMENT ONLY: Infrastructure creation
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${TERRAFORM_SA}" \
    --role="roles/compute.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${TERRAFORM_SA}" \
    --role="roles/dns.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${TERRAFORM_SA}" \
    --role="roles/storage.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${TERRAFORM_SA}" \
    --role="roles/iam.serviceAccountUser"
```

### UPI Infrastructure Permissions Breakdown

| Phase | Resource | Permission Level | Purpose | Duration |
|-------|----------|------------------|---------|----------|
| **UPI** | **Compute Engine** | `compute.admin` | Create VMs, networks, firewalls, disks | Deployment only |
| **UPI** | **Cloud DNS** | `dns.admin` | Create private DNS zones and records | Deployment only |
| **UPI** | **Cloud Storage** | `storage.admin` | Create buckets for ignition files | Deployment only |
| **UPI** | **IAM** | `iam.serviceAccountUser` | Assign service accounts to resources | Deployment only |
| **OpenShift** | **Compute Engine** | `compute.viewer` | Read instance metadata, disk info | Ongoing |
| **OpenShift** | **Cloud Storage** | `storage.objectViewer` | Pull container images | Ongoing |

## Phase 2: OpenShift Cluster Operations

### OpenShift Node Service Account (Ongoing Operations)

**IMPORTANT**: These are the minimal permissions needed for ongoing OpenShift cluster operations.

### Required Roles for OpenShift Operations

```bash
PROJECT_ID=$(gcloud config get-value project)
NODE_SA="ocp-node-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# MINIMAL REQUIRED: Compute operations
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/compute.viewer"

# MINIMAL REQUIRED: Container image access
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/storage.objectViewer"

# RECOMMENDED: Monitoring and logging (for cluster observability)
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/monitoring.metricWriter"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/logging.logWriter"
```

### OpenShift Operations Scope
These permissions enable:
- **Compute metadata access** - Node discovery and instance information
- **Container registry access** - Pull container images
- **Persistent disk operations** - Dynamic volume provisioning (CSI)
- **Load balancer integration** - Service load balancer creation
- **Monitoring data export** - Cluster metrics to GCP Monitoring
- **Log aggregation** - Cluster logs to GCP Logging

### What OpenShift DOES NOT Need
- **Compute admin** - Cannot create/delete VMs
- **Network admin** - Cannot modify VPC/subnets
- **DNS admin** - Cannot change DNS records
- **IAM admin** - Cannot modify service accounts
- **Storage admin** - Cannot create/delete buckets

### Bootstrap-Specific Permissions

For the bootstrap node to access ignition files:

```bash
# Grant bootstrap bucket access
BOOTSTRAP_BUCKET="ocp-bootstrap-ignition-$(openssl rand -hex 4)"

# Create bucket IAM binding (handled by Terraform, shown for reference)
gcloud storage buckets add-iam-policy-binding gs://${BOOTSTRAP_BUCKET} \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/storage.legacyBucketReader"

# Allow public read access to bootstrap.ign (if needed)
gcloud storage buckets add-iam-policy-binding gs://${BOOTSTRAP_BUCKET} \
    --member="allUsers" \
    --role="roles/storage.objectViewer"
```

## Security Best Practices

### 1. Two-Phase Permission Strategy

**Phase 1 - UPI Deployment (Temporary Elevated Access)**
```bash
# Use elevated permissions ONLY during deployment
# Remove or reduce permissions after infrastructure is created
```

**Phase 2 - OpenShift Operations (Minimal Ongoing Access)**
```bash
# Use minimal permissions for ongoing cluster operations
# Follow least-privilege principle for production
```

### 2. Principle of Least Privilege

- **UPI Phase**: Use broad permissions temporarily for infrastructure creation
- **Operations Phase**: Immediately reduce to minimal required permissions
- **Regular Audits**: Remove unused permissions quarterly
- **Custom Roles**: Create specific roles instead of using broad predefined ones

### 2. Service Account Key Management

```bash
# Create and download service account key securely
gcloud iam service-accounts keys create terraform-sa-key.json \
    --iam-account="${TERRAFORM_SA}"

# Set restrictive permissions on the key file
chmod 600 terraform-sa-key.json

# Use environment variable instead of storing in Terraform files
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/terraform-sa-key.json"
```

### 3. Post-Deployment Permission Cleanup

**CRITICAL**: Remove elevated UPI permissions after deployment:

```bash
# After successful deployment, remove broad Terraform permissions
gcloud projects remove-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:openshift-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/compute.admin"

gcloud projects remove-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:openshift-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/dns.admin"

gcloud projects remove-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:openshift-terraform@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/storage.admin"

# Keep only minimal ongoing permissions for OpenShift operations
# (The node service account retains compute.viewer, storage.objectViewer, etc.)
```

### 4. Temporary Deployment Permissions

For one-time deployments, use time-bound elevated permissions:

```bash
# Grant temporary admin access with expiration
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:your-email@domain.com" \
    --role="roles/owner" \
    --condition='expression=request.time < timestamp("2025-12-31T23:59:59Z"),title=Temporary OpenShift UPI Deployment'
```

### 4. Resource-Specific Permissions

Instead of project-wide permissions, consider resource-specific bindings:

```bash
# Example: Bucket-specific permissions
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/storage.objectViewer"
```

## Troubleshooting Permission Issues

### Common Permission Errors

#### 1. "Permission denied" during Terraform apply

```bash
# Check if APIs are enabled
gcloud services list --enabled | grep -E "(compute|dns|storage)"

# Verify service account permissions
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:openshift-terraform*"
```

#### 2. Bootstrap ignition fetch fails (403 Forbidden)

```bash
# Check bucket permissions
gsutil iam get gs://your-bootstrap-bucket

# Verify service account has bucket access
gcloud storage buckets get-iam-policy gs://your-bootstrap-bucket
```

#### 3. Nodes can't join cluster

```bash
# Check node service account permissions
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:ocp-node-sa*"

# Verify compute permissions
gcloud compute instances list --filter="name~'ocp-.*'"
```

### Debug Commands

```bash
# Test Terraform service account permissions
gcloud auth activate-service-account --key-file=terraform-sa-key.json
gcloud compute zones list --limit=1  # Test compute access
gcloud dns managed-zones list --limit=1  # Test DNS access
gcloud storage buckets list --limit=1  # Test storage access

# Check quota and limits
gcloud compute project-info describe --format="table(quotas.metric,quotas.limit,quotas.usage)"

# Validate APIs
gcloud services list --available --filter="name:(compute.googleapis.com OR dns.googleapis.com)" --format="table(name,title)"
```

### Permission Validation Script

```bash
#!/bin/bash
# validate-permissions.sh

PROJECT_ID=$(gcloud config get-value project)
TERRAFORM_SA="openshift-terraform@${PROJECT_ID}.iam.gserviceaccount.com"
NODE_SA="ocp-node-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Validating GCP permissions for OpenShift UPI deployment..."

# Check APIs
echo "Checking required APIs..."
for api in compute.googleapis.com dns.googleapis.com storage.googleapis.com iam.googleapis.com; do
    if gcloud services list --enabled --filter="name:${api}" --format="value(name)" | grep -q "${api}"; then
        echo "  ✓ ${api} enabled"
    else
        echo "  ✗ ${api} NOT enabled"
    fi
done

# Check service accounts exist
echo "Checking service accounts..."
if gcloud iam service-accounts describe "${TERRAFORM_SA}" >/dev/null 2>&1; then
    echo "  ✓ Terraform SA exists: ${TERRAFORM_SA}"
else
    echo "  ✗ Terraform SA missing: ${TERRAFORM_SA}"
fi

if gcloud iam service-accounts describe "${NODE_SA}" >/dev/null 2>&1; then
    echo "  ✓ Node SA exists: ${NODE_SA}"
else
    echo "  ✗ Node SA missing: ${NODE_SA}"
fi

echo "Permission validation complete."
```

## Custom IAM Roles (Advanced)

### UPI Deployment Custom Role
```bash
# Create custom role for UPI deployment (temporary use)
gcloud iam roles create openshift.upi.deployer \
    --project=$PROJECT_ID \
    --title="OpenShift UPI Deployer" \
    --description="Custom role for OpenShift UPI infrastructure deployment" \
    --permissions="compute.instances.create,compute.instances.delete,compute.instances.get,compute.instances.list,compute.instances.setServiceAccount,compute.disks.create,compute.networks.create,compute.firewalls.create,dns.managedZones.create,dns.resourceRecordSets.create,storage.buckets.create,iam.serviceAccounts.actAs"
```

### OpenShift Operations Custom Role  
```bash
# Create custom role for ongoing OpenShift operations (permanent)
gcloud iam roles create openshift.cluster.operator \
    --project=$PROJECT_ID \
    --title="OpenShift Cluster Operator" \
    --description="Minimal permissions for ongoing OpenShift cluster operations" \
    --permissions="compute.instances.get,compute.instances.list,compute.disks.get,compute.disks.list,storage.objects.get,storage.objects.list,monitoring.timeSeries.create,logging.logEntries.create"
```

## Conclusion

Proper GCP permissions are crucial for successful OpenShift UPI deployment. Start with the minimal required permissions and expand as needed. Always follow security best practices and regularly audit your IAM policies.

For production deployments, consider using:
- [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) for cluster workloads
- [IAM Conditions](https://cloud.google.com/iam/docs/conditions-overview) for time-bound or resource-specific access
- [VPC Service Controls](https://cloud.google.com/vpc-service-controls) for additional security boundaries

## References

- [GCP IAM Roles Documentation](https://cloud.google.com/iam/docs/understanding-roles)
- [OpenShift on GCP Documentation](https://docs.openshift.com/container-platform/4.19/installing/installing_gcp/installing-gcp-user-infra.html)
- [Terraform Google Provider Documentation](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

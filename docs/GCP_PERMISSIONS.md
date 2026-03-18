# GCP Permissions for OpenShift 4.19 UPI with Workload Identity Federation

Minimal IAM permissions for deploying OpenShift 4.19 UPI on GCP using Workload Identity Federation (WIF). No long-lived service account keys are created.

## Two Service Accounts, Two Purposes

| Service Account | When | Purpose | Lifetime |
|----------------|------|---------|----------|
| **Deployer SA** | During deployment | Runs Terraform, ccoctl, openshift-install, Ansible | Temporary - remove after deploy |
| **Node SA** | Cluster runtime | Attached to VMs, used by CCM for metadata auth | Permanent - lives with cluster |

The deployer SA creates everything. The node SA is what the running cluster uses. ccoctl creates additional per-operator SAs automatically (you don't manage these).

---

## Step-by-Step Manual Setup

### Step 1: Enable Required APIs

These must be enabled before anything else. You need an account with `roles/serviceusage.serviceUsageAdmin` or `roles/owner` to do this.

```bash
PROJECT_ID=$(gcloud config get-value project)

gcloud services enable compute.googleapis.com       # VMs, networks, firewalls
gcloud services enable dns.googleapis.com            # DNS zones and records
gcloud services enable storage.googleapis.com        # GCS buckets (ignition, OIDC)
gcloud services enable iam.googleapis.com            # Service accounts, custom roles
gcloud services enable iamcredentials.googleapis.com # WIF token exchange
gcloud services enable sts.googleapis.com            # WIF Security Token Service
gcloud services enable cloudresourcemanager.googleapis.com # Project metadata
```

> Terraform also enables `iam`, `iamcredentials`, and `sts` APIs via `google_project_service` resources, but they must be enabled before ccoctl runs. If you run ccoctl before Terraform (as the playbook does), enable them manually first.

### Step 2: Create the Deployer Service Account

```bash
gcloud iam service-accounts create ocp-deployer \
  --display-name="OpenShift UPI Deployer" \
  --description="Temporary SA for deploying OpenShift UPI infrastructure and WIF"
```

### Step 3: Grant Minimal Roles to the Deployer SA

```bash
DEPLOYER_SA="ocp-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

# --- Infrastructure (Terraform) ---
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/compute.admin"
  # Creates: VMs, VPC, subnets, firewalls, Cloud Router, Cloud NAT, images

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/dns.admin"
  # Creates: private DNS zone, A records for api/api-int/apps

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/storage.admin"
  # Creates: bootstrap ignition GCS bucket, OIDC discovery bucket (via ccoctl)

# --- IAM (Terraform + ccoctl) ---
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/iam.serviceAccountAdmin"
  # Creates: node SA (Terraform), per-operator SAs (ccoctl)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/iam.serviceAccountUser"
  # Attaches: node SA to VM instances

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/iam.roleAdmin"
  # Creates: custom IAM roles for operators (Terraform + ccoctl)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/iam.workloadIdentityPoolAdmin"
  # Creates: WIF pool and OIDC provider (ccoctl)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/resourcemanager.projectIamAdmin"
  # Binds: IAM policies to SAs (both Terraform and ccoctl)

# --- API management ---
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/serviceusage.serviceUsageAdmin"
  # Enables: iam, iamcredentials, sts APIs via Terraform

# --- Project metadata (openshift-install needs this) ---
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="roles/browser"
  # Reads: project metadata (resourcemanager.projects.get)
```

**Total: 10 predefined roles.** No `roles/owner`. No `roles/iam.serviceAccountKeyAdmin` (no keys needed with WIF).

### Step 4: Activate the Deployer SA

```bash
# Generate a key for local use (this is the ONLY key in the entire workflow)
gcloud iam service-accounts keys create deployer-key.json \
  --iam-account="${DEPLOYER_SA}"

chmod 600 deployer-key.json

# Activate for gcloud CLI
gcloud auth activate-service-account --key-file=deployer-key.json

# Set for Terraform and openshift-install
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/deployer-key.json"
```

### Step 5: Run the Deployment

From here, follow the deployment flow. Each tool uses the deployer SA credentials:

**5a. Generate manifests** (openshift-install uses `GOOGLE_APPLICATION_CREDENTIALS`)
```bash
openshift-install create manifests --dir=./clusterconfig
```
> Uses: `roles/browser` + `roles/compute.admin` (reads zones, machine types, DNS zones)

**5b. Extract ccoctl and CredentialsRequests**
```bash
oc adm release extract --command=ccoctl \
  quay.io/openshift-release-dev/ocp-release:4.19.0-x86_64 \
  -a ./pull --to=/usr/local/bin/

oc adm release extract --credentials-requests --cloud=gcp \
  --to=./credrequests \
  quay.io/openshift-release-dev/ocp-release:4.19.0-x86_64 \
  -a ./pull
```
> No GCP permissions needed - pulls from container registry only.

**5c. Run ccoctl** (uses gcloud CLI credentials or ADC)
```bash
ccoctl gcp create-all \
  --name=<cluster_name>-cluster \
  --region=<region> \
  --project=<project_id> \
  --credentials-requests-dir=./credrequests \
  --output-dir=./ccoctl-output
```
> Uses: `roles/iam.workloadIdentityPoolAdmin` + `roles/iam.serviceAccountAdmin` + `roles/iam.roleAdmin` + `roles/resourcemanager.projectIamAdmin` + `roles/storage.admin`

**5d. Copy ccoctl output and generate ignition**
```bash
cp ./ccoctl-output/manifests/* ./clusterconfig/manifests/
cp -r ./ccoctl-output/tls ./clusterconfig/tls
openshift-install create ignition-configs --dir=./clusterconfig
```
> No GCP permissions needed - local file operations only.

**5e. Apply Terraform**
```bash
cd terraform && terraform init && terraform apply
```
> Uses: `roles/compute.admin` + `roles/dns.admin` + `roles/storage.admin` + `roles/iam.serviceAccountAdmin` + `roles/iam.serviceAccountUser` + `roles/iam.roleAdmin` + `roles/resourcemanager.projectIamAdmin` + `roles/serviceusage.serviceUsageAdmin`

**5f. Post-bootstrap (Ansible gcloud commands)**
```bash
# DNS record updates (api-int flip, api cleanup)
gcloud dns record-sets update ...
# Instance metadata queries
gcloud compute instances describe ...
```
> Uses: `roles/dns.admin` + `roles/compute.admin`

> **Automation**: The full playbook at `ansible/openshift-upi-basic.yml` automates steps 5a-5f. See `docs/WIF_IMPLEMENTATION.md` for the ccoctl workflow details.

### Step 6: Post-Deploy Cleanup

After the cluster is running, remove the deployer SA's elevated permissions:

```bash
# Remove all deployer roles
for ROLE in \
  roles/compute.admin \
  roles/dns.admin \
  roles/storage.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/iam.roleAdmin \
  roles/iam.workloadIdentityPoolAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin \
  roles/browser; do
  gcloud projects remove-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${DEPLOYER_SA}" \
    --role="$ROLE" 2>/dev/null
done

# Delete the deployer key
rm -f deployer-key.json

# Optionally delete the deployer SA entirely
gcloud iam service-accounts delete "${DEPLOYER_SA}" --quiet
```

The cluster continues to function because:
- The **node SA** has its own permanent bindings (created by Terraform)
- The **per-operator SAs** have their own WIF bindings (created by ccoctl)
- Neither depends on the deployer SA

---

## Permissions by Tool (Reference)

### What Each Role Is Used For

| Role | Used By | What It Does |
|------|---------|-------------|
| `roles/compute.admin` | Terraform, Ansible | VMs, VPC, subnets, firewalls, router, NAT, images |
| `roles/dns.admin` | Terraform, Ansible | Private DNS zone, A records, post-bootstrap DNS flips |
| `roles/storage.admin` | Terraform, ccoctl | Bootstrap ignition bucket, OIDC discovery bucket |
| `roles/iam.serviceAccountAdmin` | Terraform, ccoctl | Node SA, per-operator WIF SAs |
| `roles/iam.serviceAccountUser` | Terraform | Attach node SA to VM instances |
| `roles/iam.roleAdmin` | Terraform, ccoctl | Custom IAM roles for operators |
| `roles/iam.workloadIdentityPoolAdmin` | ccoctl | WIF pool and OIDC provider |
| `roles/resourcemanager.projectIamAdmin` | Terraform, ccoctl | Bind IAM roles to SAs |
| `roles/serviceusage.serviceUsageAdmin` | Terraform | Enable iam/iamcredentials/sts APIs |
| `roles/browser` | openshift-install | Read project metadata |

### What Is NOT Needed

| Role | Why Not Needed |
|------|---------------|
| `roles/owner` | Too broad - the 10 roles above are sufficient |
| `roles/iam.serviceAccountKeyAdmin` | No SA keys created (WIF replaces them) |
| `roles/editor` | Too broad - includes unnecessary permissions |

---

## Node SA Permissions (Permanent)

The node SA is created by Terraform and stays for the cluster lifetime. Its permissions are:

```
roles/compute.viewer         # CCM reads instance metadata
roles/storage.admin          # Bootstrap ignition fetch, registry storage
roles/logging.logWriter      # Ship logs to GCP
roles/monitoring.metricWriter # Ship metrics to GCP
<custom_operator_role>       # 103 granular permissions for CCM LB operations
```

These are managed by Terraform (`terraform/main.tf` lines 104-147, 662-667). The custom operator role contains permissions for CSI, CCM load balancers, DNS, image registry GCS, Filestore, and Machine API.

---

## Per-Operator WIF SAs (Created by ccoctl)

ccoctl creates 7 GCP service accounts, each with a minimal custom IAM role:

| GCP SA | Operator | Key Permissions |
|--------|----------|-----------------|
| `<name>-openshift-gcp-ccm` | Cloud Controller Manager | compute instances, LBs, health checks |
| `<name>-openshift-machine-api-gcp` | Machine API | compute instances lifecycle |
| `<name>-cloud-credential-operator-gcp-ro-creds` | Cloud Credential Operator | project.get (read-only) |
| `<name>-openshift-image-registry-gcs` | Image Registry | storage buckets/objects |
| `<name>-openshift-ingress-gcp` | Ingress Operator | DNS record management |
| `<name>-openshift-cloud-network-config-controller-gcp` | Network Config Controller | compute networks/subnets read |
| `<name>-openshift-gcp-pd-csi-driver-operator` | CSI Driver | compute disks, snapshots, instances |

You don't manage these manually. ccoctl creates them with least-privilege IAM roles and WIF trust bindings. To clean them up:

```bash
ccoctl gcp delete \
  --name=<cluster_name>-cluster \
  --project=<project_id> \
  --credentials-requests-dir=./credrequests
```

---

## Custom Role Alternative (Most Restrictive)

If predefined roles are too broad, create a single custom role with only the exact permissions needed. This is the absolute minimum:

```bash
gcloud iam roles create ocp_upi_deployer \
  --project=$PROJECT_ID \
  --title="OpenShift UPI Deployer (WIF)" \
  --description="Minimal permissions for OCP 4.19 UPI deployment with WIF" \
  --permissions="\
compute.addresses.create,\
compute.addresses.delete,\
compute.addresses.get,\
compute.addresses.list,\
compute.addresses.use,\
compute.disks.create,\
compute.disks.get,\
compute.firewalls.create,\
compute.firewalls.delete,\
compute.firewalls.get,\
compute.firewalls.list,\
compute.firewalls.update,\
compute.images.create,\
compute.images.get,\
compute.images.list,\
compute.images.useReadOnly,\
compute.instances.create,\
compute.instances.delete,\
compute.instances.get,\
compute.instances.list,\
compute.instances.setMetadata,\
compute.instances.setServiceAccount,\
compute.instances.setTags,\
compute.machineTypes.get,\
compute.machineTypes.list,\
compute.networks.create,\
compute.networks.delete,\
compute.networks.get,\
compute.networks.list,\
compute.networks.updatePolicy,\
compute.regionOperations.get,\
compute.regions.get,\
compute.regions.list,\
compute.routers.create,\
compute.routers.delete,\
compute.routers.get,\
compute.routers.update,\
compute.subnetworks.create,\
compute.subnetworks.delete,\
compute.subnetworks.get,\
compute.subnetworks.list,\
compute.subnetworks.use,\
compute.zones.get,\
compute.zones.list,\
dns.changes.create,\
dns.changes.get,\
dns.changes.list,\
dns.managedZones.create,\
dns.managedZones.delete,\
dns.managedZones.get,\
dns.managedZones.list,\
dns.resourceRecordSets.create,\
dns.resourceRecordSets.delete,\
dns.resourceRecordSets.get,\
dns.resourceRecordSets.list,\
dns.resourceRecordSets.update,\
iam.roles.create,\
iam.roles.delete,\
iam.roles.get,\
iam.roles.list,\
iam.roles.update,\
iam.serviceAccounts.actAs,\
iam.serviceAccounts.create,\
iam.serviceAccounts.delete,\
iam.serviceAccounts.get,\
iam.serviceAccounts.getIamPolicy,\
iam.serviceAccounts.list,\
iam.serviceAccounts.setIamPolicy,\
iam.workloadIdentityPoolProviders.create,\
iam.workloadIdentityPoolProviders.delete,\
iam.workloadIdentityPoolProviders.get,\
iam.workloadIdentityPoolProviders.list,\
iam.workloadIdentityPools.create,\
iam.workloadIdentityPools.delete,\
iam.workloadIdentityPools.get,\
iam.workloadIdentityPools.list,\
resourcemanager.projects.get,\
resourcemanager.projects.getIamPolicy,\
resourcemanager.projects.setIamPolicy,\
serviceusage.services.enable,\
serviceusage.services.get,\
serviceusage.services.list,\
storage.buckets.create,\
storage.buckets.delete,\
storage.buckets.get,\
storage.buckets.getIamPolicy,\
storage.buckets.list,\
storage.buckets.setIamPolicy,\
storage.objects.create,\
storage.objects.delete,\
storage.objects.get,\
storage.objects.list"

# Bind the custom role
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${DEPLOYER_SA}" \
  --role="projects/${PROJECT_ID}/roles/ocp_upi_deployer"
```

---

## Gotcha: Cross-Project Service Accounts

If your deployer SA lives in a different GCP project (common in managed lab environments like RHPDS), `roles/owner` on the target project may NOT grant WIF pool permissions. You must explicitly add `roles/iam.workloadIdentityPoolAdmin`. See `docs/WIF_IMPLEMENTATION.md` gotcha #2 for details.

---

## Verification

After setup, verify the deployer SA has the right permissions:

```bash
# Activate the deployer SA
gcloud auth activate-service-account --key-file=deployer-key.json

# Test each permission area
gcloud compute zones list --limit=1                        # compute
gcloud dns managed-zones list --limit=1                    # dns
gsutil ls 2>/dev/null; echo "storage: $?"                  # storage
gcloud iam service-accounts list --limit=1                 # iam
gcloud iam workload-identity-pools list --location=global  # wif
gcloud services list --enabled --limit=1                   # serviceusage
gcloud projects describe $PROJECT_ID --format="value(name)" # browser
```

# GCP Workload Identity Federation for OpenShift 4.19 UPI

This document covers the complete implementation of GCP Workload Identity Federation (WIF) for an OpenShift 4.19 UPI cluster with `platform: gcp` and `credentialsMode: Manual`. WIF replaces long-lived GCP service account keys with short-lived, auto-refreshed tokens.

## How WIF Works

Instead of injecting a static GCP service account key into each operator namespace, WIF uses a token exchange flow:

1. The cluster's OIDC signing keys are uploaded to a **public GCS bucket**
2. A GCP **Workload Identity Pool** and **OIDC Provider** are configured to trust tokens signed by the cluster
3. Each operator pod gets a **projected Kubernetes service account token** mounted at `/var/run/secrets/openshift/serviceaccount/token`
4. When the operator needs GCP access, the Go client library reads the `external_account` credential config and:
   - Sends the K8s SA token to **GCP Security Token Service** (`sts.googleapis.com`)
   - STS validates the token against the OIDC discovery docs in the GCS bucket
   - STS returns a federated access token
   - The client exchanges this for a **short-lived GCP access token** via `iamcredentials.googleapis.com` (service account impersonation)
5. No long-lived keys exist anywhere in the cluster

### Credential Config Structure

Each operator secret contains a `service_account.json` with this structure (instead of a traditional SA key):

```json
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_NAME>/providers/<PROVIDER_NAME>",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<OPERATOR_SA_EMAIL>:generateAccessToken",
  "credential_source": {
    "file": "/var/run/secrets/openshift/serviceaccount/token",
    "format": {
      "type": "text"
    }
  }
}
```

Key differences from old approach:
- `"type": "external_account"` (not `"type": "service_account"`)
- No private key material in the secret
- Token source is a projected K8s SA token file on disk
- Each operator gets its own GCP SA with minimal IAM permissions (created by `ccoctl`)

---

## Prerequisites

### GCP Permissions

The deployer SA needs 10 specific IAM roles (not `roles/owner`). See [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md) for the complete step-by-step setup, or for the most locked-down option see the [Custom Role Alternative (Most Restrictive)](https://github.com/naeemarsalan/ocp-upi-gcp-private/blob/master/docs/GCP_PERMISSIONS.md#custom-role-alternative-most-restrictive).

### Required GCP APIs

These must be enabled before running `ccoctl`:

| API | Purpose |
|-----|---------|
| `iam.googleapis.com` | IAM API - for creating per-operator GCP service accounts |
| `iamcredentials.googleapis.com` | IAM Credentials API - for token exchange (SA impersonation) |
| `sts.googleapis.com` | Security Token Service - for WIF token exchange |
| `storage.googleapis.com` | GCS - for OIDC discovery bucket (usually already enabled) |

Enable them:
```bash
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com
```

Terraform also enables these:
```hcl
resource "google_project_service" "iam_credentials_api" {
  service = "iamcredentials.googleapis.com"
}
resource "google_project_service" "iam_api" {
  service = "iam.googleapis.com"
}
resource "google_project_service" "sts_api" {
  service = "sts.googleapis.com"
}
```

### Required GCP Permissions for ccoctl Execution

The user or service account running `ccoctl` needs permissions to create:
- Workload Identity Pools and Providers (`iam.workloadIdentityPools.*`, `iam.workloadIdentityPoolProviders.*`)
- GCP Service Accounts and IAM bindings (`iam.serviceAccounts.create`, `iam.roles.create`, etc.)
- GCS buckets and objects (`storage.buckets.create`, `storage.objects.create`)

If using a cross-project service account (e.g., from a management project), you may need to explicitly grant `roles/iam.workloadIdentityPoolAdmin` on the target project, even if the SA has `roles/owner`. This is because WIF pool operations can return 403 for cross-project identities without the explicit role.

### Required Tools

| Tool | Source | Purpose |
|------|--------|---------|
| `ccoctl` | Extracted from OCP release image | Creates WIF infrastructure and credential configs |
| `oc` | OCP client tools | Extracts ccoctl and CredentialsRequests from release image |
| `openshift-install` | OCP installer | Generates manifests and ignition configs |

Extract `ccoctl` from the release image:
```bash
oc adm release extract \
  --command=ccoctl \
  quay.io/openshift-release-dev/ocp-release:4.19.0-x86_64 \
  -a <pull_secret_path> \
  --to=<bin_directory>/
```

---

## What Changed from SA Key Injection

### Removed from Terraform

The following resources are no longer needed:

```hcl
# REMOVED - ccoctl creates per-operator SAs with fine-grained IAM
resource "google_service_account" "openshift_operator_sa" { ... }

# REMOVED - ccoctl manages its own IAM bindings
resource "google_project_iam_member" "openshift_operator_role_binding" { ... }

# REMOVED - no more long-lived keys
resource "google_service_account_key" "openshift_operator_key" { ... }

# REMOVED - no key file to write
resource "local_file" "openshift_operator_sa_key" { ... }
```

**Kept in Terraform:**
- `google_service_account.openshift_node_sa` - still needed for VM metadata (CCM uses this for cloud-provider operations via instance metadata)
- `google_project_iam_custom_role.openshift_operator_role` - still bound to node SA for CCM metadata auth
- `google_project_iam_member.openshift_node_operator_role_binding` - binds custom role to node SA

### Removed from Terraform Outputs

```hcl
# REMOVED
output "operator_service_account_email" { ... }
output "operator_sa_key_path" { ... }
```

### Removed from Ansible Variables

```yaml
# REMOVED
operator_sa_key_path: "../creds/operator-sa-key.json"
```

**Added to Ansible Variables:**
```yaml
# Pull secret for extracting release content (ccoctl, CredentialsRequests)
pull_secret_path: "../pull"

# GCP region (used by ccoctl for WIF setup)
region: "us-central1"
```

### Removed from Ansible Playbook

Two tasks were completely removed:

1. **"Copy operator SA key to bastion"** - No SA key to copy
2. **"Inject GCP credential secrets for all operators"** - The 7 operator secrets are now baked into ignition at install time

---

## Implementation: The ccoctl Workflow

The key change is that ignition generation is now a **three-step process** instead of one:

### Before (single step)
```
install-config.yaml -> openshift-install create ignition-configs -> ignition files
```

### After (three steps)
```
install-config.yaml -> openshift-install create manifests -> ccoctl -> copy manifests -> openshift-install create ignition-configs -> ignition files
```

### Step 1: Generate Manifests (not ignition)

```bash
openshift-install create manifests --dir=<clusterconfig_dir>
```

This creates the manifests directory but does NOT consume them into ignition yet. The `install-config.yaml` must have:

```yaml
credentialsMode: Manual
```

### Step 2: Extract CredentialsRequests from Release Image

```bash
oc adm release extract \
  --credentials-requests \
  --cloud=gcp \
  --to=./credrequests \
  quay.io/openshift-release-dev/ocp-release:4.19.0-x86_64 \
  -a <pull_secret_path>
```

This extracts 8 CredentialsRequest manifests for OCP 4.19:

| File | Operator |
|------|----------|
| `0000_26_cloud-controller-manager-operator_16_credentialsrequest-gcp.yaml` | Cloud Controller Manager |
| `0000_30_cluster-api_01_credentials-request.yaml` | Cluster API (tech-preview, skipped) |
| `0000_30_machine-api-operator_00_credentials-request.yaml` | Machine API |
| `0000_50_cloud-credential-operator_05-gcp-ro-credentialsrequest.yaml` | Cloud Credential Operator |
| `0000_50_cluster-image-registry-operator_01-registry-credentials-request-gcs.yaml` | Image Registry |
| `0000_50_cluster-ingress-operator_00-ingress-credentials-request.yaml` | Ingress Operator |
| `0000_50_cluster-network-operator_02-cncc-credentials.yaml` | Cloud Network Config Controller |
| `0000_50_cluster-storage-operator_03_credentials_request_gcp.yaml` | CSI Driver |

### Step 3: Run ccoctl gcp create-all

```bash
ccoctl gcp create-all \
  --name=<cluster_name>-cluster \
  --region=<region> \
  --project=<gcp_project_id> \
  --credentials-requests-dir=./credrequests \
  --output-dir=./ccoctl-output
```

**Critical: The `--name` value must be at least 4 characters.** GCP Workload Identity Pool IDs require 4-32 characters. If your cluster name is shorter (e.g., "ocp"), append a suffix like `-cluster`.

This single command creates all of the following in GCP:

**GCP Resources Created:**
- GCS bucket `<name>-oidc` (public, contains OIDC discovery docs and JWKS)
- Workload Identity Pool `<name>`
- Workload Identity OIDC Provider `<name>` (trusts tokens from the OIDC bucket issuer)
- 7 per-operator GCP service accounts (e.g., `<name>-openshift-gcp-ccm`, `<name>-openshift-gcp-pd-csi-driver-operator`)
- 7 per-operator IAM custom roles with minimal permissions
- WIF trust bindings: each K8s service account is authorized to impersonate its corresponding GCP SA

**Local Output:**
```
ccoctl-output/
  manifests/
    cluster-authentication-02-config.yaml          # Sets serviceAccountIssuer to GCS bucket URL
    openshift-cloud-controller-manager-gcp-ccm-cloud-credentials-credentials.yaml
    openshift-cloud-credential-operator-cloud-credential-operator-gcp-ro-creds-credentials.yaml
    openshift-cloud-network-config-controller-cloud-credentials-credentials.yaml
    openshift-cluster-csi-drivers-gcp-pd-cloud-credentials-credentials.yaml
    openshift-image-registry-installer-cloud-credentials-credentials.yaml
    openshift-ingress-operator-cloud-credentials-credentials.yaml
    openshift-machine-api-gcp-cloud-credentials-credentials.yaml
  tls/
    bound-service-account-signing-key.key          # RSA private key for signing SA tokens
  serviceaccount-signer.private                    # Same signing key (copy)
  serviceaccount-signer.public                     # Public key (uploaded to OIDC bucket)
```

The `cluster-authentication-02-config.yaml` sets the cluster's OIDC issuer:
```yaml
apiVersion: config.openshift.io/v1
kind: Authentication
metadata:
  name: cluster
spec:
  serviceAccountIssuer: https://storage.googleapis.com/<name>-oidc
```

### Step 4: Copy ccoctl Output into Cluster Config

```bash
cp ./ccoctl-output/manifests/* <clusterconfig_dir>/manifests/
cp -r ./ccoctl-output/tls <clusterconfig_dir>/tls
```

The manifests go into the manifests directory alongside the installer-generated manifests. The TLS signing key goes into a `tls/` directory.

### Step 5: Generate Ignition Configs

```bash
openshift-install create ignition-configs --dir=<clusterconfig_dir>
```

The installer logs should show:
```
Consuming User-provided Service Account Signing key from target directory
```

This confirms the WIF TLS key was picked up. The credential secrets and authentication config are now baked into the ignition files. When nodes boot, the operator credential secrets exist from first boot - no post-install injection needed.

---

## Deployment Flow (Updated)

1. `openshift-install create manifests` (generates manifests only)
2. Extract CredentialsRequests from release image
3. Run `ccoctl gcp create-all` (creates WIF resources + credential configs)
4. Copy ccoctl output into manifests/tls directories
5. `openshift-install create ignition-configs` (secrets baked into ignition)
6. `terraform apply` (creates VMs, network, DNS - no operator SA or key)
7. Bootstrap, DNS transitions, CSR approval (unchanged)
8. ~~Copy SA key to bastion~~ - **REMOVED**
9. ~~Inject operator secrets~~ - **REMOVED** (already in ignition)
10. Remove uninitialized taints, Filestore CSI setup, etc. (unchanged)

---

## Verification

### 1. Check Secret Type (Most Important)

The credential secret must show `"type": "external_account"`, NOT `"type": "service_account"`:

```bash
oc get secret gcp-pd-cloud-credentials -n openshift-cluster-csi-drivers \
  -o jsonpath='{.data.service_account\.json}' | base64 -d | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['type'])"
```

Expected output: `external_account`

Check all 7 operator secrets:
```bash
for ns_secret in \
  "openshift-cluster-csi-drivers/gcp-pd-cloud-credentials" \
  "openshift-cloud-controller-manager/gcp-ccm-cloud-credentials" \
  "openshift-cloud-credential-operator/cloud-credential-operator-gcp-ro-creds" \
  "openshift-cloud-network-config-controller/cloud-credentials" \
  "openshift-image-registry/installer-cloud-credentials" \
  "openshift-ingress-operator/cloud-credentials" \
  "openshift-machine-api/gcp-cloud-credentials"; do
  ns=$(echo $ns_secret | cut -d/ -f1)
  secret=$(echo $ns_secret | cut -d/ -f2)
  TYPE=$(oc get secret $secret -n $ns -o jsonpath='{.data.service_account\.json}' \
    | base64 -d | python3 -c "import json,sys; print(json.load(sys.stdin)['type'])" 2>/dev/null)
  echo "$ns/$secret: $TYPE"
done
```

All should show `external_account`.

### 2. Check Key WIF-Dependent Operators

```bash
oc get co cloud-credential cloud-controller-manager image-registry ingress storage
```

All should show `Available=True`. These operators directly use GCP credentials:
- **cloud-credential**: Verifies credential configuration
- **cloud-controller-manager**: Manages node labels, load balancers
- **image-registry**: Creates/manages GCS bucket for container images
- **ingress**: Manages DNS records for routes
- **storage**: Manages persistent disk provisioning

### 3. Verify No SA Key Files Exist

```bash
# No operator SA key should exist
ls creds/operator-sa-key.json  # Should not exist
```

### 4. Test CSI Storage (Proves WIF Token Exchange Works)

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wif-test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard-csi
EOF

# Wait and check
oc get pvc wif-test-pvc
# Should show Bound status - proves CSI driver successfully authenticated to GCP via WIF
```

---

## Security: Locking Down the OIDC Bucket

### The problem

`ccoctl gcp create-all` creates a GCS bucket (`<name>-oidc`) containing the OIDC discovery document and public signing key, then sets it to **internet-readable** (`allUsers` with `roles/storage.objectViewer`). This is unnecessary — GCP supports embedding the JWKS directly in the WIF provider, which makes the bucket irrelevant for token validation.

> **Note:** `ccoctl` does not have a `--private` flag for GCP yet. AWS has `--create-private-s3-bucket` but no GCP equivalent exists. The lockdown below is a manual post-deploy step.

### Lockdown procedure

Run these steps after `ccoctl gcp create-all` completes (before or after cluster deployment):

```bash
# Step 1: Upload JWKS directly to the WIF provider
# GCP STS will use this embedded key material instead of fetching from the bucket
gcloud iam workload-identity-pools providers update-oidc <name> \
  --workload-identity-pool=<name> \
  --location=global \
  --jwk-json-path=./ccoctl-output/keys.json

# Step 2: Remove public access from the OIDC bucket
gsutil iam ch -d allUsers:objectViewer gs://<name>-oidc

# Step 3: Verify public access is removed
gsutil iam get gs://<name>-oidc | grep allUsers
# Should return nothing
```

After this:
- The bucket is private — no internet access
- GCP STS validates tokens using the JWKS embedded in the WIF provider
- The `serviceAccountIssuer` URL in the cluster still references the bucket, but STS no longer fetches from it

### Key rotation

When rotating signing keys, update the JWKS in the WIF provider:

```bash
gcloud iam workload-identity-pools providers update-oidc <name> \
  --workload-identity-pool=<name> \
  --location=global \
  --jwk-json-path=./new-keys.json
```

GCP supports a maximum of 8 keys uploaded to a WIF provider at a time. During rotation, upload both old and new keys, wait for all tokens signed with the old key to expire (default 1 hour), then remove the old key.

### Threats and mitigations

| Threat | Impact | Mitigation |
|--------|--------|------------|
| **OIDC bucket tampering** | Attacker replaces public key with their own, enabling forged tokens | With JWKS embedded in the WIF provider, bucket tampering has no effect on token validation. Delete the deployer SA after deployment to remove write access (see [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md) Step 6). |
| **Private signing key compromise** | Attacker can forge tokens and impersonate any operator GCP SA | Key lives only in etcd on control plane nodes. Protect control plane access. Rotate immediately if compromised. |
| **Overly broad WIF trust bindings** | A compromised pod could impersonate an operator SA | ccoctl scopes each binding to a specific `system:serviceaccount:<namespace>:<sa-name>` subject — only the exact operator SA in the exact namespace can impersonate the corresponding GCP SA. |
| **Token exfiltration from a pod** | Attacker steals a projected SA token and exchanges it for a GCP token | Projected tokens are short-lived (default 1 hour) and audience-scoped to a specific WIF pool. Limit pod access with RBAC and network policies. |

### Additional hardening

1. **Delete the deployer SA after deployment** — removes the only identity with write access to the OIDC bucket
2. **Enable GCS bucket audit logging** — detect unexpected access to the OIDC bucket
3. **Monitor WIF token exchanges** — GCP audit logs record every `sts.googleapis.com` token exchange, including the source K8s SA identity

Sources:
- [GCP: Configure WIF with other identity providers](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-other-providers) — documents `--jwk-json-path` for direct JWKS upload
- [gcloud create-oidc reference](https://cloud.google.com/sdk/gcloud/reference/iam/workload-identity-pools/providers/create-oidc) — `--jwk-json-path` flag documentation
- [OpenShift CCO: Private S3 bucket PR (AWS)](https://github.com/openshift/cloud-credential-operator/pull/486) — shows the pattern exists for AWS, not yet for GCP

---

## Cleanup: Destroying WIF Resources

When tearing down the cluster, clean up WIF resources before or after `terraform destroy`:

```bash
ccoctl gcp delete \
  --name=<cluster_name>-cluster \
  --project=<gcp_project_id> \
  --credentials-requests-dir=./credrequests
```

This removes:
- The Workload Identity Pool and Provider
- All per-operator GCP service accounts
- The OIDC GCS bucket

---

## Gotchas and Lessons Learned

### 1. ccoctl --name Must Be 4+ Characters

GCP Workload Identity Pool IDs require 4-32 lowercase alphanumeric characters or hyphens. If your cluster name is 3 characters (e.g., "ocp"), ccoctl will fail with:

```
INVALID_ARGUMENT: Invalid WorkloadIdentityPool ID
```

**Fix:** Append a suffix: `--name=ocp-cluster`

### 2. Cross-Project Service Accounts May Need Explicit WIF Roles

If the GCP SA running `ccoctl` belongs to a different project than the target (common in managed lab environments), `roles/owner` on the target project may not be sufficient for WIF pool operations. You'll see:

```
Permission 'iam.workloadIdentityPools.get' denied
```

**Fix:** Explicitly grant `roles/iam.workloadIdentityPoolAdmin`:
```bash
gcloud projects add-iam-policy-binding <target_project> \
  --member="serviceAccount:<sa_email>" \
  --role="roles/iam.workloadIdentityPoolAdmin"
```

### 3. GCP APIs Must Be Enabled Before ccoctl Runs

The STS API (`sts.googleapis.com`) may not be enabled by default. If Terraform hasn't run yet (since it enables the APIs), enable them manually first:

```bash
gcloud services enable sts.googleapis.com iamcredentials.googleapis.com iam.googleapis.com
```

### 4. Manifest Generation Must Be Split from Ignition Generation

The old single-step `openshift-install create ignition-configs` must be split into:
1. `openshift-install create manifests`
2. (ccoctl steps)
3. `openshift-install create ignition-configs`

If you run `create ignition-configs` directly, it generates manifests internally and immediately consumes them - leaving no window to inject ccoctl output.

### 5. The install-config.yaml Stays the Same

`credentialsMode: Manual` works for both SA key injection and WIF. No changes needed to `install-config.yaml`.

### 6. ccoctl Skips Tech-Preview CredentialsRequests

The Cluster API CredentialsRequest (`0000_30_cluster-api_01_credentials-request.yaml`) has a tech-preview annotation and is automatically skipped by ccoctl unless `--enable-tech-preview` is passed. This is expected - the Cluster API operator is not used in standard deployments.

### 7. Node SA Is Still Required

Even with WIF, VMs still need a GCP service account attached for:
- Cloud Controller Manager metadata auth (reads instance metadata to manage nodes)
- Bootstrap ignition fetch from GCS
- General cloud-platform scope operations

The node SA and its IAM bindings remain in Terraform.

### 8. Expected UPI Degraded Operators

These operators will show Degraded regardless of WIF (they're UPI limitations, not credential issues):
- `control-plane-machine-set` - no Machine objects in UPI
- `machine-api` - no Machine objects in UPI
- `cluster-autoscaler` - depends on machine-api

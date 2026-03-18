# GCP Workload Identity Federation for OpenShift 4.19 UPI

WIF replaces long-lived GCP service account keys with short-lived, auto-refreshed tokens for an OpenShift 4.19 UPI cluster using `platform: gcp` and `credentialsMode: Manual`.

---

## Table of Contents

- [How WIF Works](#how-wif-works)
- [Prerequisites](#prerequisites)
- [What Changed from SA Key Injection](#what-changed-from-sa-key-injection)
- [Implementation](#implementation)
- [Deployment Flow](#deployment-flow)
- [Verification](#verification)
- [Security](#security)
- [Cleanup](#cleanup)
- [Gotchas](#gotchas)

---

## How WIF Works

Instead of injecting a static GCP service account key into each operator namespace, WIF uses a token exchange flow:

1. A GCP **Workload Identity Pool** and **OIDC Provider** are configured to trust tokens signed by the cluster
2. The cluster's OIDC public signing key is embedded directly in the WIF provider
3. Each operator pod gets a **projected Kubernetes service account token** mounted at `/var/run/secrets/openshift/serviceaccount/token`
4. When the operator needs GCP access, the Go client library reads the `external_account` credential config and:
   - Sends the K8s SA token to **GCP Security Token Service** (`sts.googleapis.com`)
   - STS validates the token signature against the JWKS embedded in the WIF provider
   - STS returns a federated access token
   - The client exchanges this for a **short-lived GCP access token** via `iamcredentials.googleapis.com` (service account impersonation)
5. No long-lived keys exist anywhere in the cluster

### Credential config structure

Each operator secret contains a `service_account.json` like this (instead of a traditional SA key):

```json
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<SA_EMAIL>:generateAccessToken",
  "credential_source": {
    "file": "/var/run/secrets/openshift/serviceaccount/token",
    "format": { "type": "text" }
  }
}
```

Key differences from the old approach:
- `"type": "external_account"` (not `"type": "service_account"`)
- No private key material in the secret
- Token source is a projected K8s SA token file on disk
- Each operator gets its own GCP SA with minimal permissions (created by `ccoctl`)

---

## Prerequisites

### GCP permissions

The deployer SA needs 10 specific IAM roles (not `roles/owner`). See [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md) for the step-by-step setup, or for the most locked-down option see the [Custom Role Alternative (Most Restrictive)](https://github.com/naeemarsalan/ocp-upi-gcp-private/blob/master/docs/GCP_PERMISSIONS.md#custom-role-alternative-most-restrictive).

### GCP APIs

Enable before running `ccoctl`:

```bash
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com
```

Terraform also enables `iam`, `iamcredentials`, and `sts` via `google_project_service` resources, but they must be enabled before `ccoctl` runs if you run `ccoctl` before Terraform.

### Tools

| Tool | Source | Purpose |
|------|--------|---------|
| `ccoctl` | Extracted from OCP release image | Creates WIF pool, service accounts, credential configs |
| `oc` | OCP client tools | Extracts ccoctl and CredentialsRequests from release image |
| `openshift-install` | OCP installer | Generates manifests and ignition configs |

Extract `ccoctl`:
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

```hcl
# REMOVED — ccoctl creates per-operator SAs with fine-grained IAM
resource "google_service_account" "openshift_operator_sa" { ... }
resource "google_project_iam_member" "openshift_operator_role_binding" { ... }
resource "google_service_account_key" "openshift_operator_key" { ... }
resource "local_file" "openshift_operator_sa_key" { ... }
```

**Kept in Terraform:**
- `google_service_account.openshift_node_sa` — still needed for VM metadata (CCM uses this via instance metadata)
- `google_project_iam_custom_role.openshift_operator_role` — bound to node SA for CCM metadata auth
- `google_project_iam_member.openshift_node_operator_role_binding` — binds custom role to node SA

### Removed from Terraform outputs

```hcl
output "operator_service_account_email" { ... }  # REMOVED
output "operator_sa_key_path" { ... }             # REMOVED
```

### Removed from Ansible

**Variables removed:**
```yaml
operator_sa_key_path: "../creds/operator-sa-key.json"  # REMOVED
```

**Variables added:**
```yaml
pull_secret_path: "../pull"     # For extracting ccoctl and CredentialsRequests
region: "us-central1"           # For ccoctl WIF setup
```

**Playbook tasks removed:**
1. "Copy operator SA key to bastion" — no SA key to copy
2. "Inject GCP credential secrets for all operators" — secrets are baked into ignition at install time

---

## Implementation

Ignition generation is now a multi-step process. The key change: manifests are generated first, WIF credentials are injected, then ignition is created.

```
install-config.yaml
  → openshift-install create manifests
  → ccoctl (WIF setup)
  → copy manifests + TLS
  → openshift-install create ignition-configs
```

### Step 1: Generate manifests

```bash
openshift-install create manifests --dir=<clusterconfig_dir>
```

The `install-config.yaml` must have `credentialsMode: Manual`.

### Step 2: Extract CredentialsRequests

```bash
oc adm release extract \
  --credentials-requests \
  --cloud=gcp \
  --to=./credrequests \
  quay.io/openshift-release-dev/ocp-release:4.19.0-x86_64 \
  -a <pull_secret_path>
```

This extracts 8 CredentialsRequest manifests (7 active + 1 tech-preview that ccoctl skips):

| Operator | File |
|----------|------|
| Cloud Controller Manager | `0000_26_cloud-controller-manager-operator_16_credentialsrequest-gcp.yaml` |
| Cluster API (tech-preview, skipped) | `0000_30_cluster-api_01_credentials-request.yaml` |
| Machine API | `0000_30_machine-api-operator_00_credentials-request.yaml` |
| Cloud Credential Operator | `0000_50_cloud-credential-operator_05-gcp-ro-credentialsrequest.yaml` |
| Image Registry | `0000_50_cluster-image-registry-operator_01-registry-credentials-request-gcs.yaml` |
| Ingress Operator | `0000_50_cluster-ingress-operator_00-ingress-credentials-request.yaml` |
| Cloud Network Config Controller | `0000_50_cluster-network-operator_02-cncc-credentials.yaml` |
| CSI Driver | `0000_50_cluster-storage-operator_03_credentials_request_gcp.yaml` |

### Step 3: Create WIF resources (no public bucket)

`ccoctl gcp create-all` always creates a **public** GCS bucket for the OIDC endpoint. There is no `--private` flag for GCP (AWS has `--create-private-s3-bucket`, GCP does not). You cannot pre-provision a private bucket — `ccoctl` always creates its own with `allUsers` read access.

This is unnecessary because GCP supports embedding the JWKS directly in the WIF provider via `--jwk-json-path`. Use the individual `ccoctl` sub-commands with `gcloud` to avoid the public bucket entirely:

```bash
NAME=<cluster_name>-cluster   # Must be 4+ characters (GCP WIF pool ID requirement)
PROJECT=<project_id>

# 3a: Generate the signing key pair
ccoctl gcp create-key-pair --output-dir=./ccoctl-output

# 3b: Convert public key from PEM to JWKS format
#     (ccoctl outputs PEM, but gcloud --jwk-json-path requires JWKS)
openssl rsa -pubin -in ./ccoctl-output/serviceaccount-signer.public -noout -modulus \
  | sed 's/Modulus=//' | xxd -r -p | base64 -w0 | tr '+/' '-_' | tr -d '=' | \
  jq -Rs '{keys: [{use: "sig", kty: "RSA", alg: "RS256", n: ., e: "AQAB"}]}' \
  > ./ccoctl-output/keys.json

# 3c: Create the WIF pool
ccoctl gcp create-workload-identity-pool \
  --name=$NAME \
  --project=$PROJECT \
  --output-dir=./ccoctl-output

# 3d: Create the WIF provider with gcloud (NOT ccoctl) — no bucket created
#     JWKS is embedded directly in the provider
gcloud iam workload-identity-pools providers create-oidc $NAME \
  --workload-identity-pool=$NAME \
  --location=global \
  --issuer-uri=https://storage.googleapis.com/${NAME}-oidc \
  --allowed-audiences=openshift \
  --attribute-mapping="google.subject=assertion.sub" \
  --jwk-json-path=./ccoctl-output/keys.json

# 3e: Create per-operator service accounts and credential configs
ccoctl gcp create-service-accounts \
  --name=$NAME \
  --project=$PROJECT \
  --credentials-requests-dir=./credrequests \
  --workload-identity-pool=$NAME \
  --workload-identity-provider=$NAME \
  --output-dir=./ccoctl-output
```

> The `--issuer-uri` is used as an identifier in the credential configs. Since JWKS is embedded in the provider, GCP STS never fetches from this URL. Keep the format consistent because `create-service-accounts` generates the authentication manifest using this convention.

**Alternatively**, if you prefer the simpler `create-all` command, see [Fallback: Lockdown after create-all](#fallback-lockdown-after-create-all) in the Security section.

#### What this creates

**In GCP:**
- Workload Identity Pool `<name>`
- Workload Identity OIDC Provider `<name>` (with JWKS embedded — no bucket)
- 7 per-operator GCP service accounts with minimal custom IAM roles
- WIF trust bindings: each K8s SA authorized to impersonate its corresponding GCP SA

**Locally:**
```
ccoctl-output/
  manifests/
    cluster-authentication-02-config.yaml         # Sets serviceAccountIssuer URL
    openshift-cloud-controller-manager-gcp-ccm-cloud-credentials-credentials.yaml
    openshift-cloud-credential-operator-cloud-credential-operator-gcp-ro-creds-credentials.yaml
    openshift-cloud-network-config-controller-cloud-credentials-credentials.yaml
    openshift-cluster-csi-drivers-gcp-pd-cloud-credentials-credentials.yaml
    openshift-image-registry-installer-cloud-credentials-credentials.yaml
    openshift-ingress-operator-cloud-credentials-credentials.yaml
    openshift-machine-api-gcp-cloud-credentials-credentials.yaml
  tls/
    bound-service-account-signing-key.key         # PRIVATE key — baked into ignition,
                                                  # lives on control plane only. Never uploaded.
  serviceaccount-signer.private                   # PRIVATE key — same key, stays local
  serviceaccount-signer.public                    # PUBLIC key (PEM) — converted to JWKS above,
                                                  # embedded in WIF provider. Never in a bucket.
  keys.json                                       # PUBLIC key (JWKS) — generated by step 3b
```

**Key placement summary:**
- **Private key** (`*.private`, `*.key`) → control plane nodes only (via ignition). Never uploaded anywhere.
- **Public key** (`*.public`, `keys.json`) → embedded in the WIF provider via `--jwk-json-path`. No bucket involved.

### Step 4: Copy ccoctl output into cluster config

```bash
cp ./ccoctl-output/manifests/* <clusterconfig_dir>/manifests/
cp -r ./ccoctl-output/tls <clusterconfig_dir>/tls
```

### Step 5: Generate ignition configs

```bash
openshift-install create ignition-configs --dir=<clusterconfig_dir>
```

The installer logs should show:
```
Consuming User-provided Service Account Signing key from target directory
```

This confirms the private signing key was picked up. The credential secrets and authentication config are baked into the ignition files. When nodes boot, operator secrets exist from first boot — no post-install injection needed.

---

## Deployment Flow

1. `openshift-install create manifests`
2. Extract CredentialsRequests from release image
3. Create WIF resources using ccoctl sub-commands + `gcloud` (no public bucket)
4. Copy ccoctl output into manifests/tls directories
5. `openshift-install create ignition-configs` (secrets baked into ignition)
6. `terraform apply` (creates VMs, network, DNS — no operator SA or key)
7. Bootstrap, DNS transitions, CSR approval (unchanged)
8. Remove uninitialized taints, Filestore CSI setup, etc. (unchanged)

Steps removed from old flow:
- ~~Copy SA key to bastion~~
- ~~Inject operator secrets~~

---

## Verification

### 1. Check secret type (most important)

Must show `external_account`, not `service_account`:

```bash
oc get secret gcp-pd-cloud-credentials -n openshift-cluster-csi-drivers \
  -o jsonpath='{.data.service_account\.json}' | base64 -d | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['type'])"
```

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

### 2. Check WIF-dependent operators

```bash
oc get co cloud-credential cloud-controller-manager image-registry ingress storage
```

All should show `Available=True`:
- **cloud-credential** — verifies credential configuration
- **cloud-controller-manager** — manages node labels, load balancers
- **image-registry** — creates/manages GCS bucket for container images
- **ingress** — manages DNS records for routes
- **storage** — manages persistent disk provisioning

### 3. Verify no SA key files exist

```bash
ls creds/operator-sa-key.json  # Should not exist
```

### 4. Test CSI storage (proves WIF token exchange works)

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

oc get pvc wif-test-pvc  # Should show Bound
```

---

## Security

### Two buckets in this deployment

This deployment involves two GCS buckets. Don't confuse them:

| Bucket | Created by | Contents | Risk |
|--------|-----------|----------|------|
| `<cluster>-bootstrap-ignition-<random>` | Terraform | `bootstrap.ign` — private signing key, kubeconfig, cluster secrets | **High** — full cluster secrets. Only needed during bootstrap. |
| `<cluster>-oidc` | ccoctl `create-all` only | `keys.json` (public signing key), OIDC discovery doc | **Low** — public key only, no secrets. |

The bootstrap bucket is set to `allUsers` public read because the bootstrap node fetches ignition via plain HTTPS before it has GCP credentials. It should be cleaned up after bootstrap (Terraform handles this on `terraform destroy` with `force_destroy = true`).

The OIDC bucket **is not created at all** if you follow the recommended no-bucket flow in [Step 3](#step-3-create-wif-resources-no-public-bucket). It only exists if you use `ccoctl gcp create-all`.

### Fallback: Lockdown after create-all

If you used `ccoctl gcp create-all` instead of the sub-commands, lock down the OIDC bucket immediately:

```bash
# Download the JWKS (ccoctl doesn't save it locally)
gsutil cp gs://<name>-oidc/keys.json ./ccoctl-output/keys.json

# Embed JWKS directly in the WIF provider
gcloud iam workload-identity-pools providers update-oidc <name> \
  --workload-identity-pool=<name> \
  --location=global \
  --jwk-json-path=./ccoctl-output/keys.json

# Remove public access
gsutil iam ch -d allUsers:objectViewer gs://<name>-oidc

# Verify
gsutil iam get gs://<name>-oidc | grep allUsers  # Should return nothing
```

There is a brief window between `create-all` and lockdown where the bucket is public. Only the public signing key is exposed — the private key is never in the bucket.

### Key rotation

Update the JWKS in the WIF provider:

```bash
gcloud iam workload-identity-pools providers update-oidc <name> \
  --workload-identity-pool=<name> \
  --location=global \
  --jwk-json-path=./new-keys.json
```

GCP supports up to 8 keys at a time. During rotation, upload both old and new keys, wait for tokens signed with the old key to expire (default 1 hour), then remove the old key.

### Threats and mitigations

| Threat | Impact | Mitigation |
|--------|--------|------------|
| **Private signing key compromise** | Attacker forges tokens, impersonates any operator GCP SA | Key lives only in etcd on control plane nodes. Protect control plane access. Rotate immediately if compromised. |
| **Overly broad WIF trust bindings** | Compromised pod impersonates an operator SA | ccoctl scopes each binding to `system:serviceaccount:<namespace>:<sa-name>` — only the exact operator SA can impersonate the corresponding GCP SA. |
| **Token exfiltration from a pod** | Attacker exchanges stolen token for GCP access | Projected tokens are short-lived (1 hour) and audience-scoped. Limit pod access with RBAC and network policies. |
| **OIDC bucket tampering** (create-all only) | Attacker replaces public key | With JWKS embedded in WIF provider, bucket contents are ignored. Delete deployer SA to remove write access (see [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md) Step 6). |

### Additional hardening

1. **Delete the deployer SA after deployment** — removes the only identity with write access to any buckets
2. **Enable GCS audit logging** — detect unexpected access
3. **Monitor WIF token exchanges** — GCP audit logs record every `sts.googleapis.com` exchange

### Sources

- [GCP: Configure WIF with other identity providers](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-other-providers) — `--jwk-json-path` for direct JWKS upload
- [gcloud create-oidc reference](https://cloud.google.com/sdk/gcloud/reference/iam/workload-identity-pools/providers/create-oidc) — `--jwk-json-path` flag documentation
- [OpenShift CCO: Private S3 bucket PR (AWS)](https://github.com/openshift/cloud-credential-operator/pull/486) — pattern exists for AWS, not yet for GCP

---

## Cleanup

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
- The OIDC GCS bucket (if it was created by `create-all`)

---

## Gotchas

### 1. ccoctl --name must be 4+ characters

GCP WIF pool IDs require 4-32 lowercase alphanumeric characters or hyphens. If your cluster name is 3 characters (e.g., "ocp"), `ccoctl` fails:

```
INVALID_ARGUMENT: Invalid WorkloadIdentityPool ID
```

**Fix:** Append a suffix: `--name=ocp-cluster`

### 2. Cross-project SAs may need explicit WIF roles

If the SA running `ccoctl` belongs to a different project (common in managed lab environments), `roles/owner` on the target project may not be sufficient. You'll see:

```
Permission 'iam.workloadIdentityPools.get' denied
```

**Fix:** Explicitly grant `roles/iam.workloadIdentityPoolAdmin`:
```bash
gcloud projects add-iam-policy-binding <target_project> \
  --member="serviceAccount:<sa_email>" \
  --role="roles/iam.workloadIdentityPoolAdmin"
```

### 3. GCP APIs must be enabled before ccoctl

The STS API (`sts.googleapis.com`) may not be enabled by default. Enable manually if Terraform hasn't run yet:

```bash
gcloud services enable sts.googleapis.com iamcredentials.googleapis.com iam.googleapis.com
```

### 4. Manifest generation must be split from ignition

The old single-step `openshift-install create ignition-configs` must be split into:
1. `openshift-install create manifests`
2. (ccoctl steps)
3. `openshift-install create ignition-configs`

Running `create ignition-configs` directly generates and immediately consumes manifests — no window to inject ccoctl output.

### 5. install-config.yaml stays the same

`credentialsMode: Manual` works for both SA key injection and WIF. No changes needed.

### 6. ccoctl skips tech-preview CredentialsRequests

The Cluster API CredentialsRequest has a tech-preview annotation and is skipped unless `--enable-tech-preview` is passed. This is expected.

### 7. Node SA is still required

Even with WIF, VMs need a GCP service account attached for:
- Cloud Controller Manager metadata auth
- Bootstrap ignition fetch from GCS
- General cloud-platform scope operations

The node SA and its IAM bindings remain in Terraform.

### 8. Expected UPI degraded operators

These operators show Degraded regardless of WIF (UPI limitations, not credential issues):
- `control-plane-machine-set` — no Machine objects in UPI
- `machine-api` — no Machine objects in UPI
- `cluster-autoscaler` — depends on machine-api

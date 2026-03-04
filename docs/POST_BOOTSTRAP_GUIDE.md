# From Bootstrapped to Production-Ready

Operational runbook for taking an OpenShift UPI cluster from "bootstrap complete, nodes Ready" to fully functional with working GCP integrations. For the *why* behind each component, see [GCP_PLATFORM_INTEGRATION.md](GCP_PLATFORM_INTEGRATION.md).

## Pre-Deployment: Installer Credential Requirements

When running `openshift-install create manifests` with `platform: gcp`, the installer **validates the GCP project and region** even with `credentialsMode: Manual`. It will prompt for a service account key path if no credentials are found.

### How to Provide Credentials (pick one)

| Method | Command | Notes |
|--------|---------|-------|
| Application Default Credentials (recommended) | `gcloud auth application-default login` | Uses your user identity; no SA key file needed |
| Environment variable | `export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json` | Installer reads this automatically |
| Prompt response | Enter the path when prompted | Works but less automatable |

### Minimum SA Permissions (Tested on 4.19.24)

If using a dedicated service account (not your user identity), it needs only **5 permissions** for manifest and ignition generation:

| Permission | Why |
|---|---|
| `resourcemanager.projects.get` | Validate GCP project exists |
| `compute.regions.list` | Validate the configured region |
| `compute.zones.list` | Enumerate availability zones |
| `compute.machineTypes.list` | Validate default machine type (`n2-standard-4`) |
| `dns.managedZones.list` | Find the DNS zone for the base domain |

Equivalent predefined roles: `roles/compute.viewer` + `roles/dns.reader` + `roles/browser`.

> **Important:** These are the *installer* credentials — used only during `create manifests` / `create ignition-configs`. They are **not** the operator credentials injected in [Step 1](#step-1-inject-gcp-credential-secrets). The installer does not bake these credentials into the cluster when `credentialsMode: Manual` is set.

---

## Prerequisites

### Terraform Infrastructure (Must Be Complete)

These Terraform resources must exist before starting this guide. All are defined in [`terraform/main.tf`](../terraform/main.tf).

| Resource | Terraform Name | Purpose |
|----------|---------------|---------|
| VPC network | `google_compute_network.openshift_vpc` | Cluster networking |
| Private subnets | `google_compute_subnetwork.openshift_subnets` | Node IP allocation |
| Private DNS zone | `google_dns_managed_zone.cluster_zone` | `${cluster}-zone` — cluster DNS |
| API DNS record | `google_dns_record_set.api` | `api.${domain}` → bootstrap + control plane IPs (bootstrap removed post-boot) |
| API-int DNS record | `google_dns_record_set.api_int` | `api-int.${domain}` → bootstrap IP (flipped to control planes post-boot) |
| Apps wildcard DNS | `google_dns_record_set.apps_wildcard` | `*.apps.${domain}` → worker IPs (updated in [Step 5](#step-5-update-apps-dns-to-loadbalancer-ip)) |
| Node SA | `google_service_account.openshift_node_sa` | Attached to VM instances; CCM uses via instance metadata |
| Operator SA | `google_service_account.openshift_operator_sa` | Key injected as secrets into operator namespaces |
| Operator SA key | `google_service_account_key.openshift_operator_key` | Written to `creds/operator-sa-key.json` |
| Custom IAM role | `google_project_iam_custom_role.openshift_operator_role` | 103 granular permissions for all operators |
| Operator role → Operator SA | `google_project_iam_member.openshift_operator_role_binding` | Operators authenticate via secret |
| Operator role → Node SA | `google_project_iam_member.openshift_node_operator_role_binding` | CCM authenticates via instance metadata |
| Node SA → `compute.viewer` | `google_project_iam_member.node_sa_compute_viewer` | Read instance metadata |
| Node SA → `storage.admin` | `google_project_iam_member.node_sa_storage_admin` | Image registry, bucket access |
| Health check firewall | `google_compute_firewall.allow_health_checks` | GCP LB health probes (35.191.0.0/16 etc.) |
| Ingress firewall | `google_compute_firewall.allow_ingress` | HTTP/HTTPS traffic to workers |
| NFS firewall | `google_compute_firewall.allow_filestore_nfs` | TCP/UDP 2049 for Filestore CSI |
| Bootstrap bucket | `google_storage_bucket.bootstrap_bucket` | Ignition file hosting |

For full IAM details see [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md). For the custom role's 103 permissions see [GCP_PLATFORM_INTEGRATION.md — Custom IAM Role](GCP_PLATFORM_INTEGRATION.md#4-custom-iam-role--103-granular-permissions).

### GCP APIs (Must Be Enabled)

```bash
# Verify required APIs are enabled
gcloud services list --enabled --filter="name:(
  compute.googleapis.com OR
  dns.googleapis.com OR
  storage.googleapis.com OR
  iam.googleapis.com OR
  file.googleapis.com
)" --format="value(name)"
```

`file.googleapis.com` (Cloud Filestore API) is **not** enabled by default — required for [Step 3](#step-3-enable-filestore-csi--storageclass). Enable it with `gcloud services enable file.googleapis.com`.

### Tools Required

- `oc` CLI — OpenShift client (download from cluster: `https://console-openshift-console.apps.${DOMAIN}/command-line-tools`)
- `gcloud` CLI — authenticated to `${GCP_PROJECT}` with DNS admin permissions
- `jq` — JSON processor (used in verify commands)
- SSH key at `keys/id_rsa` — for bastion access

### Shell Variables

Set these once — all commands below reference them:

```bash
export KUBECONFIG=clusterconfig/auth/kubeconfig
export CLUSTER_NAME="ocp"                              # Your cluster name
export DOMAIN="ocp.example.com"                        # Your cluster domain
export DNS_ZONE="${CLUSTER_NAME}-zone"                  # Terraform-created DNS zone name
export GCP_REGION="us-central1"                        # Your GCP region
export GCP_PROJECT="your-gcp-project-id"               # Your GCP project ID
export BASTION_IP=$(terraform -chdir=terraform output -raw bastion_external_ip)
```

### Verify Starting State

```bash
# All 5 nodes should be Ready
oc get nodes
# Expected: 3 control-plane + 2 worker nodes, all STATUS=Ready

# API should be responsive
oc get clusterversion

# Operator SA key exists
ls -la creds/operator-sa-key.json
# Expected: file exists, mode 0600
```

If nodes are not Ready or the API is not responsive, you're still in the bootstrap phase — see [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md).

> **CSR Approval:** The playbook automatically approves worker CSRs during deployment. If deploying manually, approve pending CSRs with:
> ```bash
> oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs -r oc adm certificate approve
> ```
> Re-run until no pending CSRs remain (workers submit multiple rounds).

## Where You Are Now (MVP State)

### What Works

After bootstrap completes, DNS is flipped, and CSRs are approved:
- 3 control-plane + 2 worker nodes are `Ready` (but may have CCM uninitialized taint — see Step 2)
- API server is accessible via `api` and `api-int` (both now point to control planes, bootstrap IP removed)
- etcd is running and healthy
- Core Kubernetes workloads schedule (once taints are removed)

> **Note:** The `./deploy.sh` playbook handles the DNS transition (api-int flip from bootstrap → control planes, bootstrap IP removal from api) and CSR approval automatically. If deploying manually, see [the playbook](../ansible/openshift-upi-basic.yml) for the correct sequencing — the DNS flip must wait until kube-apiserver is running on ≥2 control planes to avoid losing API connectivity.

### What Doesn't Work (The Gaps)

| # | Gap | Symptom | Fixed By |
|---|-----|---------|----------|
| 1 | Operator credentials missing | Multiple operators show `Degraded=True` | [Step 1](#step-1-inject-gcp-credential-secrets) |
| 2 | CCM uninitialized taint | Pods stuck `Pending`, node conditions incomplete | [Step 2](#step-2-remove-ccm-uninitialized-taint) |
| 3 | No RWX storage | PVCs with `ReadWriteMany` stay `Pending` | [Step 3](#step-3-enable-filestore-csi--storageclass) |
| 4 | No ingress LoadBalancer | `router-default` svc has no external IP | [Step 4](#step-4-wait-for-ingress-loadbalancer) |
| 5 | `*.apps` DNS points to worker private IPs | Console/OAuth unreachable from outside VPC | [Step 5](#step-5-update-apps-dns-to-loadbalancer-ip) |
| 6 | DNS zone name mismatch | Ingress operator `Degraded`, can't find DNS zone | [Step 6](#step-6-patch-dnsconfig-for-zone-name-mismatch) |
| 7 | Orphaned Machine API objects | Machine/MachineSet objects don't match Terraform instances | [Step 7](#step-7-clean-up-machine-api-objects) |

Check which operators are currently degraded:

```bash
oc get co | grep -v "True.*False.*False"
```

---

## Part 1: Steps the Playbook Automates

If you ran `./deploy.sh`, steps 1-4 already ran. Use the verify commands to confirm they succeeded. If any step failed, run the commands manually.

### Step 1: Inject GCP Credential Secrets

Operators need GCP credentials to manage cloud resources. Without them, they stay `Degraded`. See [GCP_PLATFORM_INTEGRATION.md — Credential Injection Pipeline](GCP_PLATFORM_INTEGRATION.md#5-credential-injection-pipeline).

> **Terraform:** `google_service_account.openshift_operator_sa`, `google_service_account_key.openshift_operator_key` (generates `creds/operator-sa-key.json`)
> **IAM:** Custom role bound to operator SA via `google_project_iam_member.openshift_operator_role_binding` — includes permissions for PD CSI, CCM, Ingress, Image Registry, Machine API, Filestore CSI, and CCO ([103 permissions](GCP_PLATFORM_INTEGRATION.md#4-custom-iam-role--103-granular-permissions))

**Command:**

```bash
# Path to the operator SA key generated by Terraform
SA_KEY="creds/operator-sa-key.json"

# Create secrets in all 7 operator namespaces
declare -A SECRETS=(
  ["openshift-cluster-csi-drivers"]="gcp-pd-cloud-credentials"
  ["openshift-cloud-controller-manager"]="gcp-ccm-cloud-credentials"
  ["openshift-cloud-credential-operator"]="cloud-credential-operator-gcp-ro-creds"
  ["openshift-cloud-network-config-controller"]="cloud-credentials"
  ["openshift-image-registry"]="installer-cloud-credentials"
  ["openshift-ingress-operator"]="cloud-credentials"
  ["openshift-machine-api"]="gcp-cloud-credentials"
)

for ns in "${!SECRETS[@]}"; do
  oc create secret generic "${SECRETS[$ns]}" \
    --from-file=service_account.json="$SA_KEY" \
    -n "$ns" --dry-run=client -o yaml | oc apply -f -
done
```

**Verify:**

```bash
for ns in openshift-cluster-csi-drivers openshift-cloud-controller-manager \
  openshift-cloud-credential-operator openshift-cloud-network-config-controller \
  openshift-image-registry openshift-ingress-operator openshift-machine-api; do
  echo "$ns: $(oc get secret -n $ns -o name | grep -c 'cloud\|gcp\|installer')"
done
# Expected: each namespace shows at least 1
```

### Step 2: Remove CCM Uninitialized Taint

The `platform: gcp` setting causes kubelet to taint every node as `uninitialized`, blocking pod scheduling. The taint must be removed manually during initial deployment. See [GCP_PLATFORM_INTEGRATION.md — CCM Taint](GCP_PLATFORM_INTEGRATION.md#6-ccm-taint--chicken-and-egg-problem).

> **Terraform:** Node SA (`google_service_account.openshift_node_sa`) must have the custom operator role bound via `google_project_iam_member.openshift_node_operator_role_binding` — CCM uses instance metadata credentials (node SA) to manage nodes, not the operator SA secret.
> **IAM:** Requires `compute.instances.get`, `compute.instances.list`, `compute.instances.setLabels`, `compute.instances.setTags` (all included in the custom role)

**Command:**

```bash
for node in $(oc get nodes -o name); do
  oc adm taint $node node.cloudprovider.kubernetes.io/uninitialized- 2>/dev/null || true
done
```

> **Note:** Workers also receive this taint when they join the cluster. If you run this step before workers are Ready, re-run it after approving worker CSRs (the `for node` loop is idempotent — already-untainted nodes are silently skipped).

**Verify:**

```bash
oc get nodes -o json | jq '[.items[].spec.taints // [] | .[] |
  select(.key == "node.cloudprovider.kubernetes.io/uninitialized")] | length'
# Expected: 0
```

### Step 3: Enable Filestore CSI + StorageClass

Filestore CSI provides RWX (ReadWriteMany) NFS volumes. The driver must be explicitly enabled and a StorageClass created. See [GCP_PLATFORM_INTEGRATION.md — Filestore CSI](GCP_PLATFORM_INTEGRATION.md#9-storage-gcp-filestore-csi-rwx-nfs).

> **Terraform:** VPC (`google_compute_network.openshift_vpc`) — referenced in StorageClass `network` parameter. NFS firewall rule (`google_compute_firewall.allow_filestore_nfs`) — allows TCP/UDP 2049 from subnets to cluster nodes.
> **IAM:** Requires `file.instances.*` and `file.operations.*` (included in the custom role)
> **GCP API:** `file.googleapis.com` must be enabled — not enabled by default

**Command:**

```bash
# Enable the Filestore CSI driver
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: filestore.csi.storage.gke.io
spec:
  managementState: Managed
EOF

# Create the StorageClass (replace <cluster>-vpc with your VPC name)
oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-rwx
provisioner: filestore.csi.storage.gke.io
parameters:
  connect-mode: DIRECT_PEERING
  network: ${CLUSTER_NAME}-vpc
  tier: BASIC_HDD
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF
```

> **Note:** The `network` parameter must match your Terraform VPC name: `${CLUSTER_NAME}-vpc` (e.g., `ocp-vpc`).

**Verify:**

```bash
oc get clustercsidriver filestore.csi.storage.gke.io
# Expected: shows Managed

oc get sc filestore-rwx
# Expected: shows the filestore-rwx StorageClass
```

### Step 4: Wait for Ingress LoadBalancer

Once CCM is running with proper credentials, it provisions a GCP LoadBalancer for the ingress router. This takes 2-5 minutes. See [GCP_PLATFORM_INTEGRATION.md — LoadBalancer Services](GCP_PLATFORM_INTEGRATION.md#7-loadbalancer-services).

> **Terraform:** Health check firewall (`google_compute_firewall.allow_health_checks`) — allows GCP health probes from `35.191.0.0/16`, `130.211.0.0/22`, `209.85.152.0/22`, `209.85.204.0/22`. Ingress firewall (`google_compute_firewall.allow_ingress`) — allows HTTP/HTTPS from `ingress_source_ranges` to worker nodes.
> **IAM:** CCM uses instance metadata (node SA) — requires LB permissions: `compute.addresses.*`, `compute.forwardingRules.*`, `compute.targetPools.*`, `compute.regionBackendServices.*`, `compute.healthChecks.*`, `compute.instanceGroups.*`, `compute.firewalls.*` (all included in the custom role bound to node SA)

**Command:**

```bash
echo "Waiting for ingress LoadBalancer IP..."
while true; do
  LB_IP=$(oc get svc router-default -n openshift-ingress \
    -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null)
  if [[ -n "$LB_IP" ]]; then
    echo "LoadBalancer IP: $LB_IP"
    break
  fi
  echo "  Still waiting..."
  sleep 15
done
```

**Verify:**

```bash
oc get svc router-default -n openshift-ingress
# Expected: EXTERNAL-IP shows a public IP (not <pending>)
```

If the LB stays `<pending>` for more than 10 minutes, check CCM logs:

```bash
oc logs -n openshift-cloud-controller-manager \
  -l k8s-app=cloud-controller-manager --tail=50
```

---

## Part 2: Manual Steps (You Must Do These)

The playbook stops after Part 1. These steps are required for a production-ready cluster.

### Step 5: Update `*.apps` DNS to LoadBalancer IP

Terraform initially sets the `*.apps` wildcard DNS record to worker private IPs. Once the ingress LoadBalancer is provisioned, the DNS must be updated to the LB's public IP — otherwise the console and OAuth are unreachable from outside the VPC.

> **Terraform:** Initial wildcard record (`google_dns_record_set.apps_wildcard`) points to worker private IPs. DNS zone (`google_dns_managed_zone.cluster_zone`) is named `${cluster}-zone`.
> **IAM:** The `gcloud dns` command runs as your user account (not the operator SA) — requires `dns.admin` or `dns.resourceRecordSets.update` on the project. See [GCP_PERMISSIONS.md — Phase 1](GCP_PERMISSIONS.md#phase-1-upi-deployment-permissions).

**Command:**

```bash
# Get the LoadBalancer IP (should already be set from Step 4)
LB_IP=$(oc get svc router-default -n openshift-ingress \
  -o jsonpath="{.status.loadBalancer.ingress[0].ip}")

echo "Updating *.apps DNS to $LB_IP"

# Update the wildcard record
gcloud dns record-sets update "*.apps.${DOMAIN}." \
  --zone="${DNS_ZONE}" \
  --type=A \
  --ttl=300 \
  --rrdatas="${LB_IP}"
```

**Verify:**

```bash
# Check DNS record was updated
gcloud dns record-sets list --zone="${DNS_ZONE}" \
  --filter="name=*.apps.${DOMAIN}." --format="table(name,type,rrdatas)"
# Expected: rrdatas shows the LB public IP

# Test DNS resolution from the bastion
ssh -i keys/id_rsa ubuntu@${BASTION_IP} \
  "nslookup console-openshift-console.apps.${DOMAIN}"
# Expected: resolves to the LB IP
```

### Step 6: Patch dns.config for Zone Name Mismatch

The Ingress Operator expects the private DNS zone to be named `{infra-name}-private-zone` (e.g., `ocp-5wd4k-private-zone`), but Terraform creates it as `${CLUSTER_NAME}-zone` (e.g., `ocp-zone`). Without this patch, the Ingress Operator stays `Degraded`. See [GCP_PLATFORM_INTEGRATION.md — DNS Zone Patching](GCP_PLATFORM_INTEGRATION.md#10-dns-zone-patching-infrastructure-name-mismatch).

> **Terraform:** DNS zone (`google_dns_managed_zone.cluster_zone`) is named `${cluster}-zone`. The Ingress Operator expects `{infra-name}-private-zone` — this mismatch is inherent to UPI with Terraform-managed DNS.
> **IAM:** Ingress Operator uses the operator SA secret in `openshift-ingress-operator` — requires `dns.changes.*`, `dns.managedZones.*`, `dns.resourceRecordSets.*` (included in the custom role)

**Command:**

```bash
# Check the current (broken) state
oc get dns.config cluster -o jsonpath='{.spec}' | jq .
# Expected: privateZone.id shows something like "ocp-5wd4k-private-zone"

# Patch to the actual zone name
oc patch dns.config cluster --type merge \
  -p "{\"spec\":{\"privateZone\":{\"id\":\"${DNS_ZONE}\"}}}"
```

**Verify:**

```bash
# Confirm the patch
oc get dns.config cluster -o jsonpath='{.spec.privateZone.id}'
# Expected: ocp-zone (or whatever your DNS_ZONE is)

# Wait ~1 minute, then check the ingress operator
oc get co ingress
# Expected: Available=True, Degraded=False
```

### Step 7: Clean Up Machine API Objects

The installer creates Machine and MachineSet objects that reference GCP instances by the generated infrastructure name. In UPI, these don't match the Terraform-created instances. Cleaning them up prevents confusing errors. See [GCP_PLATFORM_INTEGRATION.md — Machine API for UPI](GCP_PLATFORM_INTEGRATION.md#11-machine-api-for-upi).

> **Terraform:** Instances are named `${cluster}-control-{1,2,3}` and `${cluster}-worker-{1,2}` (`google_compute_instance.control_plane`, `google_compute_instance.worker`). The installer-generated Machine objects expect names like `${infra-name}-master-{0,1,2}` — they will never match.
> **IAM:** Machine API uses the operator SA secret in `openshift-machine-api` — requires `compute.instances.*`, `compute.machineTypes.*`, `compute.images.*` (included in the custom role). Safe to leave bound even after cleanup.

**Command:**

```bash
# Scale all MachineSets to 0
for ms in $(oc get machinesets -n openshift-machine-api -o name); do
  oc scale "$ms" --replicas=0 -n openshift-machine-api
done

# Delete all Machine objects
oc delete machines --all -n openshift-machine-api
```

**Verify:**

```bash
oc get machines -n openshift-machine-api
# Expected: No resources found

oc get machinesets -n openshift-machine-api
# Expected: all replicas = 0
```

> **Note:** The `control-plane-machine-set` operator will show `Degraded` — this is expected for UPI and can be safely ignored.

### Step 8: Remove Bootstrap Node (Optional)

The bootstrap node is no longer needed after the control plane is running. Removing it saves compute cost.

> **Terraform:** Bootstrap instance (`google_compute_instance.bootstrap`), bootstrap bucket (`google_storage_bucket.bootstrap_bucket`). Note: deleting via `gcloud` leaves these in Terraform state — run `terraform state rm google_compute_instance.bootstrap` afterward to avoid drift, or remove via `terraform destroy -target=google_compute_instance.bootstrap`.
> **IAM:** The `gcloud compute instances delete` command runs as your user account — requires `compute.instances.delete` on the project. See [GCP_PERMISSIONS.md — Phase 1](GCP_PERMISSIONS.md#phase-1-upi-deployment-permissions).

**Command:**

```bash
# Find the bootstrap instance zone
BOOTSTRAP_ZONE=$(gcloud compute instances list \
  --filter="name=${CLUSTER_NAME}-bootstrap" \
  --format="value(zone)")

# Delete the bootstrap instance
gcloud compute instances delete "${CLUSTER_NAME}-bootstrap" \
  --zone="${BOOTSTRAP_ZONE}" --quiet
```

**Verify:**

```bash
gcloud compute instances list --filter="name~${CLUSTER_NAME}"
# Expected: bootstrap instance is gone; 3 control + 2 worker + 1 bastion remain
```

---

## Final Health Check

Run this block to verify the cluster is production-ready:

```bash
echo "=== Nodes ==="
oc get nodes
echo ""

echo "=== Cluster Operators ==="
oc get co
echo ""

echo "=== Cluster Version ==="
oc get clusterversion
echo ""

echo "=== Storage Classes ==="
oc get sc
echo ""

echo "=== Ingress LoadBalancer ==="
oc get svc router-default -n openshift-ingress \
  -o wide
echo ""

echo "=== Console Route ==="
oc get route console -n openshift-console \
  -o jsonpath='{.spec.host}{"\n"}'
echo ""

echo "=== DNS Records ==="
gcloud dns record-sets list --zone="${DNS_ZONE}" \
  --format="table(name,type,rrdatas)"
echo ""

echo "=== Degraded Operators ==="
oc get co | grep -v "True.*False.*False" | tail -n +2
echo "(empty = all operators healthy)"
```

### Expected Final State

- **Nodes**: 3 control-plane + 2 workers, all `Ready`
- **Cluster Operators**: all `Available=True`, `Progressing=False`, `Degraded=False` (except `control-plane-machine-set`, `machine-api`, and `cluster-autoscaler` which are `Degraded` — expected for UPI)
- **Cluster Version**: `Available=True`
- **Storage Classes**: `standard-csi` (default), `ssd-csi` (PD CSI), `filestore-rwx` (Filestore CSI)
- **Ingress**: `router-default` has a public `EXTERNAL-IP`
- **Console**: accessible at `https://console-openshift-console.apps.${DOMAIN}`
- **DNS**: `*.apps` points to the LoadBalancer IP

### Console Access

```bash
# Console URL
echo "https://console-openshift-console.apps.${DOMAIN}"

# Admin credentials
echo "Username: kubeadmin"
echo "Password: $(cat clusterconfig/auth/kubeadmin-password)"
```

---

## Troubleshooting

| Problem | Check Command | Documentation |
|---------|--------------|---------------|
| Operators degraded after credential injection | `oc get co; oc logs -n openshift-cloud-credential-operator -l app=cloud-credential-operator` | [GCP_PLATFORM_INTEGRATION.md — Credential Injection](GCP_PLATFORM_INTEGRATION.md#5-credential-injection-pipeline) |
| LoadBalancer not provisioning | `oc logs -n openshift-cloud-controller-manager -l k8s-app=cloud-controller-manager --tail=50` | [GCP_PLATFORM_INTEGRATION.md — LoadBalancer Services](GCP_PLATFORM_INTEGRATION.md#7-loadbalancer-services) |
| Console unreachable after DNS update | `nslookup console-openshift-console.apps.${DOMAIN}; curl -kI https://console-openshift-console.apps.${DOMAIN}` | [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md) |
| Filestore PVC stuck pending | `oc describe pvc <name>; gcloud filestore instances list` | [GCP_PLATFORM_INTEGRATION.md — Filestore CSI](GCP_PLATFORM_INTEGRATION.md#9-storage-gcp-filestore-csi-rwx-nfs) |

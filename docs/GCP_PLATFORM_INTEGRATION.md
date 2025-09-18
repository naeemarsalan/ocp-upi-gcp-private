# GCP Platform Integration Guide

How to run OpenShift 4.19 UPI with `platform: gcp` and `credentialsMode: Manual` — covering IAM, credential injection, Cloud Controller Manager, LoadBalancer services, Persistent Disk CSI, and Filestore CSI.

## 1. Overview

### Why `platform: gcp` Instead of `platform: none`

Standard UPI guides use `platform: none`, which treats the cluster as bare-metal. Setting `platform: gcp` tells OpenShift the underlying cloud is GCP, which enables:

- **Cloud Controller Manager (CCM)** — manages node lifecycle, provisions GCP network LoadBalancers for `type: LoadBalancer` services
- **GCP Persistent Disk CSI** — built-in dynamic provisioning of RWO block volumes
- **GCP Filestore CSI** — dynamic provisioning of RWX NFS volumes
- **Ingress Operator** — creates DNS records in GCP Cloud DNS
- **Image Registry** — uses GCS buckets for image storage
- **Machine API** — can scale nodes via GCP APIs (optional for UPI)

Without `platform: gcp`, none of these integrations work and you must run everything manually or with third-party solutions.

### Why `credentialsMode: Manual`

In IPI (Installer Provisioned Infrastructure), the installer creates service accounts and injects credentials automatically. In UPI, the installer doesn't manage infrastructure, so it can't create SAs or inject keys. Setting `credentialsMode: Manual` tells all operators to expect pre-created secrets rather than managing their own credentials.

The relevant `install-config.yaml` fields:

```yaml
platform:
  gcp:
    projectID: your-gcp-project-id
    region: us-central1
credentialsMode: Manual
```

## 2. GCP API Requirements

Enable these APIs before deployment:

```bash
gcloud services enable compute.googleapis.com
gcloud services enable dns.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable file.googleapis.com    # Required for Filestore CSI
```

The `file.googleapis.com` (Cloud Filestore API) is **not** enabled by default and must be explicitly enabled if you want RWX storage.

## 3. IAM Architecture: Two Service Accounts

This deployment uses two GCP service accounts with distinct roles:

### Node SA (`<cluster>-node-sa`)

- **Attached to VM instances** via instance metadata (the `service_account` block in Terraform)
- **CCM reads credentials from instance metadata**, not from Kubernetes secrets
- Needs the custom operator IAM role bound to it because CCM uses the node SA for LoadBalancer operations
- Also has `roles/compute.viewer`, `roles/storage.admin`, `roles/logging.logWriter`, `roles/monitoring.metricWriter`

Terraform resource: `google_service_account.openshift_node_sa`

### Operator SA (`<cluster>-operator-sa`)

- **Key is injected as Kubernetes secrets** into 7 operator namespaces
- Operators read credentials from the secret's `service_account.json` key
- Only has the custom operator IAM role

Terraform resources: `google_service_account.openshift_operator_sa`, `google_service_account_key.openshift_operator_key`

### Why Both SAs Need the Custom Role

The CCM runs as a pod and uses the node instance metadata credentials (node SA) for LB operations — not the secret-injected operator SA. If the node SA doesn't have LB permissions, CCM can authenticate but every LB create/delete call fails with 403.

Terraform bindings:
```hcl
# Operator SA gets the custom role (for secret-based operators)
google_project_iam_member.openshift_operator_role_binding

# Node SA also gets the custom role (for CCM via instance metadata)
google_project_iam_member.openshift_node_operator_role_binding
```

## 4. Custom IAM Role — 103 Granular Permissions

The custom role (`google_project_iam_custom_role.openshift_operator_role`) contains 103 unique permissions organized by operator. All permissions are defined in `terraform/main.tf` lines 526-647.

### GCP PD CSI Driver (Persistent Disk Management)
```
compute.disks.create
compute.disks.delete
compute.disks.get
compute.disks.list
compute.disks.update
compute.disks.resize
compute.disks.setLabels
compute.instances.attachDisk
compute.instances.detachDisk
compute.instances.get
compute.instances.list
compute.snapshots.create
compute.snapshots.delete
compute.snapshots.get
compute.snapshots.list
compute.zones.get
compute.zones.list
```

### Cloud Controller Manager (Node & LB Management)
```
compute.instances.setLabels
compute.instances.setTags
compute.addresses.get
compute.addresses.list
compute.forwardingRules.get
compute.forwardingRules.list
compute.regionBackendServices.get
compute.regionBackendServices.list
compute.instanceGroups.get
compute.instanceGroups.list
compute.targetPools.get
compute.targetPools.list
```

### Cloud Network Config Controller
```
compute.networks.get
compute.networks.list
compute.subnetworks.get
compute.subnetworks.list
```

### Image Registry (GCS Bucket Management)
```
storage.buckets.create
storage.buckets.delete
storage.buckets.get
storage.buckets.list
storage.objects.create
storage.objects.delete
storage.objects.get
storage.objects.list
```

### Ingress Operator (DNS Record Management)
```
dns.changes.create
dns.changes.get
dns.changes.list
dns.managedZones.get
dns.managedZones.list
dns.resourceRecordSets.create
dns.resourceRecordSets.delete
dns.resourceRecordSets.get
dns.resourceRecordSets.list
dns.resourceRecordSets.update
```

### Machine API (Instance Lifecycle)
```
compute.instances.create
compute.instances.delete
compute.instances.use
compute.machineTypes.get
compute.machineTypes.list
compute.images.get
compute.images.getFromFamily
compute.images.useReadOnly
```

### Load Balancer (CCM Creates LBs for Services)
```
compute.addresses.create
compute.addresses.delete
compute.addresses.use
compute.forwardingRules.create
compute.forwardingRules.delete
compute.forwardingRules.setTarget
compute.targetPools.create
compute.targetPools.delete
compute.targetPools.addInstance
compute.targetPools.removeInstance
compute.targetPools.use
compute.regionBackendServices.create
compute.regionBackendServices.delete
compute.regionBackendServices.update
compute.regionBackendServices.use
compute.healthChecks.create
compute.healthChecks.delete
compute.healthChecks.get
compute.healthChecks.use
compute.healthChecks.useReadOnly
compute.httpHealthChecks.create
compute.httpHealthChecks.delete
compute.httpHealthChecks.get
compute.httpHealthChecks.use
compute.httpHealthChecks.useReadOnly
compute.instanceGroups.create
compute.instanceGroups.delete
compute.instanceGroups.update
compute.instanceGroups.use
compute.regionOperations.get
compute.firewalls.create
compute.firewalls.delete
compute.firewalls.get
compute.firewalls.update
compute.networks.updatePolicy
compute.projects.get
```

### Filestore CSI Driver
```
file.instances.create
file.instances.delete
file.instances.get
file.instances.list
file.instances.update
file.operations.get
file.operations.list
```

### Cloud Credential Operator (Read-Only Verification)
```
resourcemanager.projects.get
```

## 5. Credential Injection Pipeline

The operator SA key flows through this pipeline:

1. **Terraform** generates the key: `google_service_account_key.openshift_operator_key`
2. **Terraform** writes it to disk: `creds/operator-sa-key.json` (mode 0600)
3. **Ansible** copies the key to the bastion host
4. **Ansible** creates secrets in 7 namespaces using `kubectl create secret generic`

All secrets use the key `service_account.json` containing the full operator SA JSON key.

| Namespace | Secret Name |
|-----------|-------------|
| `openshift-cluster-csi-drivers` | `gcp-pd-cloud-credentials` |
| `openshift-cloud-controller-manager` | `gcp-ccm-cloud-credentials` |
| `openshift-cloud-credential-operator` | `cloud-credential-operator-gcp-ro-creds` |
| `openshift-cloud-network-config-controller` | `cloud-credentials` |
| `openshift-image-registry` | `installer-cloud-credentials` |
| `openshift-ingress-operator` | `cloud-credentials` |
| `openshift-machine-api` | `gcp-cloud-credentials` |

These secret names are not arbitrary — each operator watches for a specific secret name in its own namespace. If the name is wrong, the operator stays degraded.

Reference: `ansible/openshift-upi-basic.yml` lines 450-457.

## 6. CCM Taint — Chicken-and-Egg Problem

When `platform: gcp` is set, kubelet adds this taint to every node at boot:

```
node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
```

The intended flow is: CCM starts, verifies the node against GCP, and removes the taint. But there's a chicken-and-egg problem:

1. The taint prevents **all** pods from scheduling on the node (including etcd)
2. CCM needs etcd to be running before it can start
3. etcd can't start because the taint blocks it

**Solution**: The playbook removes the taint from all nodes after workers join:

```bash
for node in $(kubectl get nodes -o name); do
  kubectl taint $node node.cloudprovider.kubernetes.io/uninitialized- 2>/dev/null || true
done
```

Once CCM is running, it manages taint removal for any new nodes that join the cluster. This manual step is only needed during initial deployment.

Reference: `ansible/openshift-upi-basic.yml` lines 464-477.

## 7. LoadBalancer Services

### How It Works

With `platform: gcp` and the proper IAM permissions, CCM automatically provisions GCP network LoadBalancers for any Kubernetes service with `type: LoadBalancer`. The OpenShift ingress router gets an external LoadBalancer IP automatically.

### Required Firewall Rules

Terraform creates these rules to support LoadBalancer health checks and traffic:

**Health check probes** (`<cluster>-allow-health-checks`):
- Source ranges: `35.191.0.0/16`, `130.211.0.0/22`, `209.85.152.0/22`, `209.85.204.0/22`
- All TCP ports
- Targets: all cluster nodes

**Ingress traffic** (`<cluster>-allow-ingress`):
- Ports: 80, 443
- Source: `0.0.0.0/0` (configurable via `ingress_source_ranges`)
- Targets: worker nodes

### DNS Considerations

The `*.apps` DNS wildcard record must point to the LoadBalancer external IP (not worker private IPs) for the OAuth callback and console to be accessible from outside the VPC.

The playbook waits for the LB to provision:

```bash
LB_IP=$(kubectl get svc router-default -n openshift-ingress \
  -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
```

If `*.apps` DNS still points to worker private IPs (as Terraform initially sets), update it:

```bash
# Get the LB IP
LB_IP=$(kubectl get svc router-default -n openshift-ingress \
  -o jsonpath="{.status.loadBalancer.ingress[0].ip}")

# Update DNS
gcloud dns record-sets update "*.apps.<domain>." \
  --zone=<cluster>-zone --type=A --ttl=300 --rrdatas="$LB_IP"
```

## 8. Storage: GCP Persistent Disk CSI

GCP PD CSI is built into OpenShift and works automatically once the credential secrets are injected (section 5).

- Provides **RWO** (ReadWriteOnce) block volumes
- Default StorageClass: `standard-csi` (pd-standard) and `premium-rwo` (pd-ssd)
- Requires these IAM permissions: `compute.disks.*`, `compute.instances.attachDisk`, `compute.instances.detachDisk`, `compute.snapshots.*`, `compute.zones.*`

No additional configuration is needed — creating a PVC will dynamically provision a GCP Persistent Disk.

## 9. Storage: GCP Filestore CSI (RWX NFS)

Filestore CSI provides **RWX** (ReadWriteMany) volumes backed by GCP Filestore (managed NFS).

### Prerequisites

1. **API enabled**: `gcloud services enable file.googleapis.com`
2. **IAM permissions**: `file.instances.*` and `file.operations.*` (included in the custom role)
3. **NFS firewall rule**: TCP/UDP port 2049 — created by Terraform as `<cluster>-allow-filestore-nfs`

### Enable the Driver

Apply the ClusterCSIDriver CRD:

```yaml
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: filestore.csi.storage.gke.io
spec:
  managementState: Managed
```

### Create the StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-rwx
provisioner: filestore.csi.storage.gke.io
parameters:
  connect-mode: DIRECT_PEERING
  network: <cluster>-vpc
  tier: BASIC_HDD
allowVolumeExpansion: true
volumeBindingMode: Immediate
```

Replace `<cluster>-vpc` with your actual VPC name (e.g., `ocp-vpc`).

### Usage Notes

- **Minimum volume size**: 1Ti (Filestore BASIC_HDD minimum). PVCs requesting less will be rounded up.
- **Provisioning time**: 5-10 minutes per Filestore instance
- **connect-mode**: `DIRECT_PEERING` routes NFS traffic through VPC peering, keeping it private

The playbook (`ansible/openshift-upi-basic.yml` lines 483-515) handles both the ClusterCSIDriver and StorageClass creation.

## 10. DNS Zone Patching (Infrastructure Name Mismatch)

`openshift-install` generates an infrastructure name (e.g., `ocp-5wd4k`) that gets baked into the cluster config. The Ingress Operator expects the private DNS zone to be named `{infra-name}-private-zone`, but Terraform creates it as `<cluster>-zone` (e.g., `ocp-zone`).

Fix this by patching the DNS config:

```bash
kubectl patch dns.config cluster --type merge \
  -p '{"spec":{"privateZone":{"id":"<cluster>-zone"}}}'
```

Without this patch, the Ingress Operator can't find the DNS zone and stays degraded. The `*.apps` wildcard record won't be updated by the operator.

## 11. Machine API for UPI

When `platform: gcp` is set, the installer creates Machine and MachineSet objects that reference GCP instances. In UPI, these objects don't match the Terraform-created instances (different naming convention).

To clean this up:

```bash
# Scale all MachineSets to 0
for ms in $(kubectl get machinesets -n openshift-machine-api -o name); do
  kubectl scale $ms --replicas=0 -n openshift-machine-api
done

# Delete orphaned Machine objects
kubectl delete machines --all -n openshift-machine-api
```

The `control-plane-machine-set` operator will show `Degraded` — this is expected for UPI and can be ignored.

## 12. Teardown Considerations

### CCM-Created Resources Are Not Managed by Terraform

When CCM provisions LoadBalancers, it creates GCP resources with `k8s-` prefixed names:
- Forwarding rules (`k8s-fw-*`)
- Target pools (`k8s-*`)
- Firewall rules (`k8s-fw-*`)
- Addresses (`k8s-*`)

These are **not** in Terraform state. If you run `terraform destroy` without cleaning them up first, they'll be orphaned and may block VPC/network deletion.

### Clean Up Before Destroy

```bash
# Delete forwarding rules
for rule in $(gcloud compute forwarding-rules list \
  --filter="name~k8s-" --format="value(name,region)" | awk '{print $1}'); do
  gcloud compute forwarding-rules delete "$rule" --region=<region> --quiet
done

# Delete target pools
for pool in $(gcloud compute target-pools list \
  --filter="name~k8s-" --format="value(name)"); do
  gcloud compute target-pools delete "$pool" --region=<region> --quiet
done

# Delete firewall rules
for fw in $(gcloud compute firewall-rules list \
  --filter="name~k8s-fw-" --format="value(name)"); do
  gcloud compute firewall-rules delete "$fw" --quiet
done

# Delete addresses
for addr in $(gcloud compute addresses list \
  --filter="name~k8s-" --format="value(name)"); do
  gcloud compute addresses delete "$addr" --region=<region> --quiet
done
```

Replace `<region>` with your GCP region (e.g., `us-central1`).

### GCP Service Account Soft-Delete

GCP retains deleted service accounts for 30 days. If you destroy and recreate infrastructure, the SA account ID will conflict. Use `terraform import` to adopt the existing SA:

```bash
terraform import google_service_account.openshift_operator_sa \
  projects/<project>/serviceAccounts/<cluster>-operator-sa@<project>.iam.gserviceaccount.com

terraform import google_service_account.openshift_node_sa \
  projects/<project>/serviceAccounts/<cluster>-node-sa@<project>.iam.gserviceaccount.com
```

### Filestore Instances

Any provisioned Filestore instances (from PVCs) must also be deleted before destroying the VPC, as they create VPC peering connections. Delete the PVCs first, then wait for the Filestore instances to be removed:

```bash
# Check for Filestore instances
gcloud filestore instances list --format="table(name,state,networks)"
```

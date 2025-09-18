# OpenShift UPI GCP Debug Commands

This document contains all the debug commands used to troubleshoot the OpenShift UPI deployment on GCP.

## Quick Troubleshooting Workflow

### 1. Check Infrastructure Status
```bash
# Verify all VMs are running
gcloud compute instances list --format='table(name,status,zone,internalIP)'

# Check cluster nodes from bastion
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl get nodes"
```

### 2. Common DNS Issues Fix
```bash
# Check current DNS records
gcloud dns record-sets list --zone=ocp-zone

# Fix API DNS pointing to control planes instead of bootstrap
gcloud dns record-sets transaction start --zone=ocp-zone
gcloud dns record-sets transaction remove --zone=ocp-zone --name=api.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 BOOTSTRAP_IP
gcloud dns record-sets transaction add --zone=ocp-zone --name=api.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 CONTROL_IP1 CONTROL_IP2 CONTROL_IP3
gcloud dns record-sets transaction execute --zone=ocp-zone

# Fix Apps DNS pointing to workers instead of VIP
gcloud dns record-sets transaction start --zone=ocp-zone  
gcloud dns record-sets transaction remove --zone=ocp-zone --name=*.apps.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 VIP_IP
gcloud dns record-sets transaction add --zone=ocp-zone --name=*.apps.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 WORKER_IP1 WORKER_IP2 WORKER_IP3
gcloud dns record-sets transaction execute --zone=ocp-zone
```

### 3. Worker Nodes Not Joining Fix  
```bash
# Check for pending CSRs
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl get csr | grep Pending"

# Approve all pending CSRs
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl certificate approve \$(kubectl get csr -o name | grep Pending)"

# Or approve specific CSRs
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl certificate approve csr-xxxxx csr-yyyyy"
```

### 4. Test Cluster Access
```bash
# Test API connectivity  
ssh -i keys/id_rsa ubuntu@BASTION_IP "curl -k https://api.ocp.j7ql2.gcp.redhatworkshops.io:6443/readyz"

# Test console access from worker node
ssh -i keys/id_rsa ubuntu@BASTION_IP "ssh -i ~/.ssh/id_rsa core@WORKER_IP 'curl -H \"Host: console-openshift-console.apps.ocp.j7ql2.gcp.redhatworkshops.io\" https://localhost -k'"

# Check cluster operators
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl get clusteroperators"
```

## 1. General Cluster Status

### Check all cluster instances
```bash
gcloud compute instances list --filter="name~ocp-" --format="table(name,status,zone.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP)" | sort
```

### Get terraform outputs
```bash
terraform output
```

### Check ignition files locally
```bash
ls -la clusterconfig/
head -5 clusterconfig/master.ign && echo "..." && tail -5 clusterconfig/master.ign
head -1 clusterconfig/worker.ign | jq .
cat clusterconfig/bootstrap-pointer.ign
```

## 2. DNS Troubleshooting

### Check DNS zone configuration
```bash
gcloud dns managed-zones describe ocp-zone --format="yaml"
gcloud dns record-sets list --zone=ocp-zone
```

### Test DNS resolution from bastion
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="nslookup api-int.ocp.j7ql2.gcp.redhatworkshops.io"
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="dig @169.254.169.254 api-int.ocp.j7ql2.gcp.redhatworkshops.io"
```

### Test external DNS (should fail for private zone)
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="nslookup api-int.ocp.j7ql2.gcp.redhatworkshops.io 8.8.8.8"
```

## 3. Bootstrap Node Debugging

### Check bootstrap node status
```bash
gcloud compute instances describe ocp-bootstrap --zone=us-central1-a --format="value(status)"
```

### Get bootstrap console logs
```bash
gcloud compute instances get-serial-port-output ocp-bootstrap --zone=us-central1-a | tail -20
gcloud compute instances get-serial-port-output ocp-bootstrap --zone=us-central1-a | grep -E "(bootstrap|ignition|22623|Machine Config)" | tail -10
```

### SSH to bootstrap node
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="ssh -i key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 core@10.0.1.12 'COMMAND'"
```

### Check Machine Config Server
```bash
# Test if MCS port is listening
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 10 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'netstat -tuln | grep :22623'"

# Test MCS health endpoint
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="curl -k -s https://10.0.1.12:22623/healthz"
```

### Fetch ignition configs from MCS
```bash
# Get master ignition config
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="curl -k -s https://10.0.1.12:22623/config/master | head -10"

# Get worker ignition config
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="curl -k -s https://10.0.1.12:22623/config/worker | head -10"
```

### Check bootkube service
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 15 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'systemctl status bootkube --no-pager -l'"

gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 20 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'journalctl -u bootkube.service --no-pager -n 30'"
```

### Check podman containers on bootstrap
```bash
# List containers
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 20 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'sudo podman ps -a'"

# Check container logs
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 30 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'for pod in \$(sudo podman ps -a -q); do echo \"=== Container \$pod ===\"; sudo podman logs \$pod 2>&1 | tail -20; echo; done'"
```

## 4. Control Plane Debugging

### Check control plane console logs
```bash
# General logs
gcloud compute instances get-serial-port-output ocp-control-1 --zone=us-central1-a | tail -20

# Ignition attempts
gcloud compute instances get-serial-port-output ocp-control-1 --zone=us-central1-a | grep -E "(GET.*22623|ignition|success|Failed|error)" | tail -10

# DNS lookup errors
gcloud compute instances get-serial-port-output ocp-control-1 --zone=us-central1-a | grep -E "(lookup.*api-int|no such host)" | tail -5
```

### Check control plane last start time
```bash
gcloud compute instances describe ocp-control-1 --zone=us-central1-a --format="value(lastStartTimestamp)"
```

### Reset control plane nodes
```bash
gcloud compute instances reset ocp-control-1 --zone=us-central1-a
gcloud compute instances reset ocp-control-2 --zone=us-central1-b
gcloud compute instances reset ocp-control-3 --zone=us-central1-c
```

### SSH to control plane (when accessible)
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 10 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.11 'COMMAND'"
```

## 5. Network Connectivity Testing

### Test internet access
```bash
# From bastion
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="curl -s -m 5 https://quay.io/v2/ && echo 'Internet access working!' || echo 'Internet access not working'"

# Test specific ports
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 5 telnet 10.0.1.12 22623"
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 5 telnet 10.0.1.12 22"
```

### Check Cloud NAT
```bash
gcloud compute routers list
gcloud compute routers describe ocp-router --region=us-central1
```

## 6. System Status Checks

### Check system status on nodes
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 10 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'systemctl is-system-running'"

gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 20 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'journalctl --failed --no-pager'"
```

### Check specific services
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 15 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.12 'systemctl status NetworkManager --no-pager'"
```

## 7. Ignition File Verification

### Validate ignition JSON
```bash
head -1 clusterconfig/master.ign | jq .
head -1 clusterconfig/worker.ign | jq .
cat clusterconfig/bootstrap-pointer.ign | jq .
```

### Check file sizes
```bash
ls -lh clusterconfig/
wc -c clusterconfig/bootstrap-pointer.ign
wc -c clusterconfig/bootstrap.ign
```

### Verify GCS bootstrap file
```bash
gsutil ls -l gs://openenv-j7ql2-rhcos-images/bootstrap.ign
gsutil acl get gs://openenv-j7ql2-rhcos-images/bootstrap.ign
```

## 8. RHCOS Image Issues

### Check if RHCOS image exists
```bash
# List RHCOS images
gcloud compute images list --filter="name~rhcos" --format="table(name,family,creationTimestamp,status)"

# Check specific image used by Terraform
gcloud compute images describe rhcos-4-19-10

# Check image family
gcloud compute images list --filter="family=rhcos"
```

### Create RHCOS image if missing
```bash
# Download RHCOS image
curl -o rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz \
  https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.19/4.19.10/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz

# Upload to GCS and create image
export PROJECT_ID=$(gcloud config get-value project)
gsutil mb gs://${PROJECT_ID}-rhcos-temp
gsutil cp rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz gs://${PROJECT_ID}-rhcos-temp/
gcloud compute images create rhcos-4-19-10 \
  --source-uri gs://${PROJECT_ID}-rhcos-temp/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz \
  --family rhcos \
  --description "Red Hat CoreOS 4.19.10 for OpenShift"

# Cleanup
gsutil rm gs://${PROJECT_ID}-rhcos-temp/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz
gsutil rb gs://${PROJECT_ID}-rhcos-temp
rm rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz
```

### Troubleshoot image creation issues
```bash
# Check image creation operation status
gcloud compute operations list --filter="operationType=insert AND targetType=images"

# Check if bucket exists and has permissions
gsutil ls -L gs://${PROJECT_ID}-rhcos-temp/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz

# Verify file integrity
gsutil hash gs://${PROJECT_ID}-rhcos-temp/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz
```

## 9. GCP Resource Checks

### Check firewall rules
```bash
gcloud compute firewall-rules list --filter="name~ocp" --format="table(name,direction,priority,sourceRanges.list():label=SRC_RANGES,allowed[].map().firewall_rule().list():label=ALLOW,targetTags.list():label=TARGET_TAGS)"
```

### Check subnet configuration
```bash
gcloud compute networks subnets list --filter="name~ocp" --format="table(name,region,ipCidrRange,secondaryIpRanges[].rangeName,secondaryIpRanges[].ipCidrRange)"
```

### Check VPC configuration
```bash
gcloud compute networks describe ocp-vpc
```

## 10. Emergency Recovery Commands

### Add manual DNS entry to hosts file
```bash
gcloud compute ssh ocp-bastion --zone=us-central1-a --command="timeout 15 ssh -i key -o StrictHostKeyChecking=no core@10.0.1.11 'echo \"10.0.1.12 api-int.ocp.j7ql2.gcp.redhatworkshops.io\" | sudo tee -a /etc/hosts'"
```

### Force terraform state refresh
```bash
terraform refresh
terraform plan
```

### Clean up and redeploy specific resources
```bash
terraform taint google_compute_instance.control_plane[0]
terraform taint google_compute_instance.control_plane[1] 
terraform taint google_compute_instance.control_plane[2]
terraform apply
```

## 11. Troubleshooting Tips

### Common Issues and Solutions

1. **DNS Resolution Issues**
   - Check private DNS zone configuration
   - Verify DNS records point to correct IPs
   - Test DNS resolution from within VPC
   - Wait for DNS propagation (5-15 minutes)

2. **Bootstrap Not Accessible**
   - Check Cloud NAT for internet access
   - Verify ignition file size (<262KB for GCP metadata)
   - Use pointer ignition files for large configs
   - Check bootstrap node console logs

3. **Control Planes Stuck in Ignition**
   - Verify Machine Config Server is running on bootstrap
   - Check DNS resolution to api-int hostname
   - Reset control plane nodes after bootstrap is ready
   - Monitor ignition attempt logs

4. **Network Connectivity Issues**
   - Verify firewall rules allow required ports
   - Check Cloud NAT configuration
   - Test subnet connectivity
   - Verify VPC access for private DNS

### Key Ports to Monitor
- **22**: SSH access
- **22623**: Machine Config Server
- **6443**: Kubernetes API server
- **2379-2380**: etcd cluster
- **9000-9999**: Node ports
- **10250**: Kubelet API

### Important Log Locations
- `/var/log/messages`: System logs
- `journalctl -u bootkube`: Bootstrap service
- `journalctl -u kubelet`: Kubelet service
- `journalctl -u crio`: Container runtime
- Console logs via `gcloud compute instances get-serial-port-output`

## 12. Specific Issue: DNS Records Point to Bootstrap Instead of Control Planes

### Symptoms
- API server unreachable after bootstrap completion
- Control plane nodes can't communicate with API
- Error: `dial tcp 10.0.1.5:6443: connect: connection refused`

### Diagnosis
```bash
# Check current DNS records
gcloud dns record-sets list --zone=ocp-zone

# Should show API pointing to bootstrap IP instead of control planes
# api.ocp.j7ql2.gcp.redhatworkshops.io.    A    300    10.0.1.5  # WRONG
```

### Fix
```bash
# Get control plane IPs
gcloud compute instances describe ocp-control-1 --zone=us-central1-a --format='get(networkInterfaces[0].networkIP)'
gcloud compute instances describe ocp-control-2 --zone=us-central1-b --format='get(networkInterfaces[0].networkIP)'
gcloud compute instances describe ocp-control-3 --zone=us-central1-c --format='get(networkInterfaces[0].networkIP)'

# Update DNS to point to control planes
gcloud dns record-sets transaction start --zone=ocp-zone
gcloud dns record-sets transaction remove --zone=ocp-zone --name=api.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 10.0.1.5
gcloud dns record-sets transaction add --zone=ocp-zone --name=api.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 10.0.1.2 10.0.2.2 10.0.3.3
gcloud dns record-sets transaction execute --zone=ocp-zone
```

## 13. Specific Issue: Worker Nodes Not Joining Cluster

### Symptoms
- Only control plane nodes visible in `kubectl get nodes`
- Worker kubelet logs show: `User "system:anonymous" cannot get resource "nodes"`
- CSRs stuck in pending state

### Diagnosis
```bash
# Check for pending CSRs
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl get csr | grep Pending"

# Check worker kubelet status
ssh -i keys/id_rsa ubuntu@BASTION_IP "ssh -i ~/.ssh/id_rsa core@WORKER_IP 'sudo systemctl status kubelet --no-pager'"
```

### Fix
```bash
# Approve all pending worker CSRs
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl certificate approve csr-xxxxx csr-yyyyy csr-zzzzz"

# Wait for nodes to appear
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl get nodes"

# May need to approve additional serving CSRs
ssh -i keys/id_rsa ubuntu@BASTION_IP "export KUBECONFIG=~/clusterconfig/auth/kubeconfig && kubectl get csr | grep Pending"
```

## 14. Specific Issue: Apps/Console Not Accessible

### Symptoms
- Console URL returns connection refused
- `*.apps` domain not resolving correctly
- DNS points to VIP with no backend

### Diagnosis
```bash
# Check apps DNS record
gcloud dns record-sets list --zone=ocp-zone | grep apps
# *.apps.ocp.j7ql2.gcp.redhatworkshops.io.   A     300    10.0.1.10  # VIP with no backend

# Test console from worker node directly (should work)
ssh -i keys/id_rsa ubuntu@BASTION_IP "ssh -i ~/.ssh/id_rsa core@WORKER_IP 'curl -H \"Host: console-openshift-console.apps.ocp.j7ql2.gcp.redhatworkshops.io\" https://localhost -k'"
```

### Fix
```bash
# Get worker node IPs
gcloud compute instances describe ocp-worker-1 --zone=us-central1-a --format='get(networkInterfaces[0].networkIP)'
gcloud compute instances describe ocp-worker-2 --zone=us-central1-b --format='get(networkInterfaces[0].networkIP)'
gcloud compute instances describe ocp-worker-3 --zone=us-central1-c --format='get(networkInterfaces[0].networkIP)'

# Update apps DNS to point to workers
gcloud dns record-sets transaction start --zone=ocp-zone
gcloud dns record-sets transaction remove --zone=ocp-zone --name=*.apps.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 10.0.1.10
gcloud dns record-sets transaction add --zone=ocp-zone --name=*.apps.ocp.j7ql2.gcp.redhatworkshops.io. --type=A --ttl=300 10.0.1.4 10.0.2.3 10.0.3.2
gcloud dns record-sets transaction execute --zone=ocp-zone
```

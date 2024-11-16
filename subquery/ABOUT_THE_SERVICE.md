# zkSync Indexer Recovery Guide

This document provides the steps required to restore the zkSync indexer service in case of a failure on one or more of the VMs running the indexers.

## General Information

- **Project**: zkSync indexer using SubQuery
- **Infrastructure**: 7 VMs in Google Cloud Platform (GCP)
- **Primary Dependencies**: Docker and Docker Compose

## Recovery Steps

### 1. Access the Affected VM

1. Identify the VM experiencing issues.
2. Connect to the affected VM via SSH using the GCP console or your local terminal:

```bash
gcloud compute ssh [vm-name] --zone=[vm-zone]
```

### 2. Restart Service with Docker Compose

1. Navigate to the project directory where docker-compose.yml is located.
2. Inspect the docker-compose.yml file to identify the three services and locate the affected one.
3. Restart the specific service or all services if necessary:

```bash
# Restart a specific service
docker-compose restart [service-name]

# Or restart all services
docker-compose down && docker-compose up -d
```

### 3. Check Docker Logs
Review Docker logs for more details on the error and confirm the service has restarted correctly:

```bash
docker logs [service-name]
```

### 4. Verify VM Resources
Check if the VM requires additional resources, such as disk space. To increase disk space:

1. **Stop the VM** in the GCP console.
2. Access the VM settings to increase the storage.
3. **Restart the VM** after the resource changes.

Note: Changing disk size may update the public IP of the VM.

### 5. Update IP in Cloudflare
If the VM IP changes, update the corresponding proxy in Cloudflare:

1. Log in to your Cloudflare account.
2. Go to the domain associated with this VM.
3. Update the IP in the proxy settings to restore connectivity to the service.
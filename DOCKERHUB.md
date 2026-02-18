# CloudStack Simulator with Usage Service

The official Apache CloudStack simulator image extended with the **Usage Server** for billing, metering, and resource consumption testing.

## What's Included

This image runs **4 services** inside a single container:

| Service | Description |
|---------|-------------|
| **MySQL** | Database server |
| **Management Server** | CloudStack API and simulator backend |
| **Usage Server** | Processes and aggregates usage/billing data |
| **UI** | CloudStack web interface |

## Quick Start

### Docker

```bash
docker run -d --name cloudstack-simulator-usage \
  -p 8080:5050 \
  registry.assistanz24x7.com:4443/stackbill/cloudstack-simulator-usage:4.20.1.0
```

### Docker Compose

```yaml
version: '3.8'
services:
  cloudstack-simulator:
    image: registry.assistanz24x7.com:4443/stackbill/cloudstack-simulator-usage:4.20.1.0
    container_name: cloudstack-simulator-usage
    ports:
      - "8080:5050"
    environment:
      - USAGE_AGGREGATION_RANGE=5
    volumes:
      - db-data:/var/lib/mysql
    restart: unless-stopped

volumes:
  db-data:
```

### Podman

```bash
sudo podman run -d --name cloudstack-simulator-usage \
  -p 8080:5050 \
  registry.assistanz24x7.com:4443/stackbill/cloudstack-simulator-usage:4.20.1.0
```

## Port

| Host | Container | Service |
|------|-----------|---------|
| 8080 | 5050 | CloudStack UI + API (Nginx reverse proxy) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USAGE_AGGREGATION_RANGE` | `5` | How often usage data is aggregated, in minutes |

## Startup

The container takes **3-4 minutes** to fully start. Monitor progress:

```bash
docker logs -f cloudstack-simulator-usage
```

Verify all services are running:

```bash
docker exec cloudstack-simulator-usage supervisorctl status
```

## Access

- **URL:** http://localhost:8080
- **Login:** admin / password

The Infrastructure page shows the Usage Server status as **Up**.

## Deploy a Zone

```bash
docker exec cloudstack-simulator-usage \
  python /root/tools/marvin/marvin/deployDataCenter.py \
  -i /root/setup/dev/advanced.cfg
```

Wait ~2 minutes for system VMs to start.

Available zone configs: `advanced.cfg`, `advancedsg.cfg`, `basic.cfg`

## Test Usage Records

After deploying a zone and creating resources (VMs, volumes, etc.):

```bash
# Trigger usage record generation
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=generateUsageRecords&domainid=1&response=json"

# List usage records
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listUsageRecords&domainid=1&response=json"
```

Usage records are also generated automatically every 5 minutes (configurable via `USAGE_AGGREGATION_RANGE`).

## Usage Types Tracked

| Type | What It Measures |
|------|------------------|
| RUNNING_VM | VM running time |
| ALLOCATED_VM | VM lifecycle |
| IP_ADDRESS | Public IP ownership |
| NETWORK_BYTES_SENT | Outbound traffic |
| NETWORK_BYTES_RECEIVED | Inbound traffic |
| VOLUME | Disk volume lifecycle |
| TEMPLATE | Template storage |
| SNAPSHOT | Snapshot lifecycle |

## Available Tags

| Tag | CloudStack Version |
|-----|-------------------|
| `latest` | CloudStack 4.20.1.0 |
| `4.20.1.0` | CloudStack 4.20.1.0 |
| `4.19.1.0` | CloudStack 4.19.1.0 |

## Common Commands

```bash
# View logs
docker logs -f cloudstack-simulator-usage

# Restart usage server
docker exec cloudstack-simulator-usage supervisorctl restart cloudstack-usage

# Check usage config
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listConfigurations&name=enable.usage.server&response=json"

# Shell into container
docker exec -it cloudstack-simulator-usage bash

# Stop (keeps data)
docker stop cloudstack-simulator-usage

# Stop and remove data
docker rm -v cloudstack-simulator-usage
```

## Links

- [GitHub](https://github.com/vigneshvrm/cloudstack-simulator-usage)
- [Official CloudStack Simulator](https://hub.docker.com/r/apache/cloudstack-simulator)
- [CloudStack Usage Docs](https://docs.cloudstack.apache.org/en/latest/adminguide/usage.html)

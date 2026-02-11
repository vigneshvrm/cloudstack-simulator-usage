# CloudStack Simulator with Usage Service

An enhanced Apache CloudStack simulator Docker image that includes the **Usage Service** for billing, metering, and resource consumption testing.

## Why?

The official `apache/cloudstack-simulator` image does **not** include the Usage Service. This means you cannot test:
- `listUsageRecords` API
- `generateUsageRecords` API
- Billing/metering integrations
- Usage-based workflows

This image adds the Usage Service as a 4th managed process alongside MySQL, Management Server, and UI.

---

## Prerequisites

- Docker Engine 20.10+ installed and running
- Docker Compose v2+ installed
- At least **8 GB RAM** available for Docker (Maven build is memory-heavy)
- At least **15 GB disk space** (source + Maven cache + built artifacts)
- Internet access (to clone repo + download Maven dependencies)

---

## Step-by-Step Deployment

### Step 1: Get the Project Files

```bash
cd /path/to/cloudstack-simulator-usage
```

Ensure you have these files in the directory:
```
cloudstack-simulator-usage/
├── Dockerfile
├── supervisord.conf
├── docker-compose.yml
├── setup-usage.sql
├── README.md
└── scripts/
    └── entrypoint.sh
```

### Step 2: Build the Docker Image

**Option A — Using docker-compose (recommended):**

```bash
# Build with default CloudStack version (4.20.1.0)
docker-compose build

# OR build with a specific version
CS_VERSION=4.19.1.0 docker-compose build
```

**Option B — Using docker build directly:**

```bash
# Default version
docker build -t cloudstack-simulator-usage:4.20.1.0 .

# Specific version
docker build --build-arg CS_VERSION=4.19.1.0 -t cloudstack-simulator-usage:4.19.1.0 .
```

> **Note:** The first build takes 15-30+ minutes (clones repo, runs full Maven build, installs Node.js UI). Subsequent builds use Docker cache.

### Step 3: Start the Container

```bash
docker-compose up -d
```

Or with custom settings:

```bash
# Custom usage aggregation interval (default is 5 minutes)
USAGE_AGGREGATION_RANGE=10 docker-compose up -d
```

### Step 4: Wait for Services to Start

The container runs 4 services sequentially. Monitor startup progress:

```bash
# Watch logs in real-time
docker logs -f cloudstack-simulator-usage
```

**Startup order and approximate times:**

| Order | Service | Ready After |
|-------|---------|-------------|
| 1 | MySQL | ~5 seconds |
| 2 | CloudStack Management Server | ~2-3 minutes |
| 3 | CloudStack Usage Server | ~30 seconds after mgmt server |
| 4 | CloudStack UI | ~10 seconds |

**Check all services are running:**

```bash
docker exec -it cloudstack-simulator-usage supervisorctl status
```

Expected output:
```
cloudstack-management    RUNNING   pid 123, uptime 0:03:00
cloudstack-ui            RUNNING   pid 456, uptime 0:02:30
cloudstack-usage         RUNNING   pid 789, uptime 0:01:00
mysqld                   RUNNING   pid 100, uptime 0:03:30
```

**Check health via API:**

```bash
curl -s "http://localhost:8096/client/api?command=listZones&response=json"
```

If you get a JSON response (even with empty results), the management server is ready.

### Step 5: Deploy an Advanced Zone (No Security Groups)

```bash
docker exec -it cloudstack-simulator-usage \
  python /root/cloudstack/tools/marvin/marvin/deployDataCenter.py \
  -i /root/cloudstack/setup/dev/advanced.cfg
```

This creates:
- 1 Zone, 1 Pod, 1 Cluster
- Simulated hosts (no real hypervisors needed)
- Primary and secondary storage (simulated)
- Network offerings, compute offerings
- System VMs (CPVM, SSVM, Virtual Router)

> **Wait ~1-2 minutes** after deploy for system VMs to start.

**Verify the zone deployed:**

```bash
curl -s "http://localhost:8096/client/api?command=listZones&response=json" | python3 -m json.tool
```

### Step 6: Create Some Resources (to Generate Usage Data)

Deploy a VM to start generating usage records:

```bash
# List available service offerings
curl -s "http://localhost:8096/client/api?command=listServiceOfferings&response=json" | python3 -m json.tool

# List available templates
curl -s "http://localhost:8096/client/api?command=listTemplates&templatefilter=all&response=json" | python3 -m json.tool

# Deploy a VM (use IDs from above responses)
curl -s "http://localhost:8096/client/api?command=deployVirtualMachine&serviceofferingid=<SERVICE_OFFERING_ID>&templateid=<TEMPLATE_ID>&zoneid=<ZONE_ID>&response=json" | python3 -m json.tool
```

### Step 7: Verify Usage Service is Working

**7a. Confirm usage server is enabled:**

```bash
curl -s "http://localhost:8096/client/api?command=listConfigurations&name=enable.usage.server&response=json" | python3 -m json.tool
```

Expected: `"value": "true"`

**7b. Manually trigger usage record generation:**

```bash
curl -s "http://localhost:8096/client/api?command=generateUsageRecords&domainid=1&response=json" | python3 -m json.tool
```

> You can also wait for the automatic aggregation (every 5 minutes by default).

**7c. List usage records:**

```bash
curl -s "http://localhost:8096/client/api?command=listUsageRecords&domainid=1&response=json" | python3 -m json.tool
```

You should see records for RUNNING_VM, ALLOCATED_VM, VOLUME, TEMPLATE, etc.

### Step 8: Access the UI (Optional)

Open in browser: **http://localhost:8080/**

Login credentials:
- **Username:** admin
- **Password:** password

---

## Available Zone Configurations

| Config File | Zone Type |
|-------------|-----------|
| `advanced.cfg` | Advanced zone (no security groups) — **recommended** |
| `advancedsg.cfg` | Advanced zone with security groups |
| `basic.cfg` | Basic zone |
| `advancedtf.cfg` | Advanced zone (Terraform-friendly) |
| `advdualzone.cfg` | Dual advanced zones |

---

## Configuration Reference

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `CS_VERSION` | `4.20.1.0` | CloudStack Git tag/branch to build |
| `CS_REPO` | `https://github.com/apache/cloudstack.git` | CloudStack Git repository URL |

### Runtime Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USAGE_AGGREGATION_RANGE` | `5` | Usage aggregation interval in minutes |

### Ports

| Port | Service |
|------|---------|
| 8080 | CloudStack UI |
| 8096 | CloudStack API (unauthenticated integration port) |
| 5050 | Internal simulator port |

### Services (managed by supervisord)

| Service | Priority | Description |
|---------|----------|-------------|
| MySQL | 100 | Database server |
| CloudStack Management Server | 200 | API + simulator backend |
| CloudStack Usage Server | 300 | Usage/billing data processing |
| CloudStack UI | 400 | Web interface |

---

## Usage Types Tracked

| ID | Type | Description |
|----|------|-------------|
| 1 | RUNNING_VM | VM running time |
| 2 | ALLOCATED_VM | VM lifecycle (create to destroy) |
| 3 | IP_ADDRESS | Public IP ownership |
| 4 | NETWORK_BYTES_SENT | Outbound network data |
| 5 | NETWORK_BYTES_RECEIVED | Inbound network data |
| 6 | VOLUME | Disk volume lifecycle |
| 7 | TEMPLATE | Template storage |
| 8 | ISO | ISO file usage |
| 9 | SNAPSHOT | Snapshot lifecycle |
| 11 | LOAD_BALANCER_POLICY | LB policy lifecycle |
| 12 | PORT_FORWARDING_RULE | Port forwarding lifecycle |
| 13 | NETWORK_OFFERING | Network offering assignment |
| 14 | VPN_USERS | VPN user lifecycle |

---

## Common Operations

### Stop the container
```bash
docker-compose down
```

### Stop and remove data (fresh start)
```bash
docker-compose down -v
```

### View logs
```bash
# All services
docker logs -f cloudstack-simulator-usage

# Specific service
docker exec -it cloudstack-simulator-usage supervisorctl tail -f cloudstack-usage
docker exec -it cloudstack-simulator-usage supervisorctl tail -f cloudstack-management
```

### Restart a specific service
```bash
docker exec -it cloudstack-simulator-usage supervisorctl restart cloudstack-usage
```

### Enter the container shell
```bash
docker exec -it cloudstack-simulator-usage bash
```

---

## Version Support

Build any CloudStack release tag:

```bash
# Current release
CS_VERSION=4.20.1.0 docker-compose build

# Previous LTS
CS_VERSION=4.19.1.0 docker-compose build

# Build from main branch (bleeding edge)
CS_VERSION=main docker-compose build
```

---

## Troubleshooting

### Management server not starting
- Check logs: `docker logs cloudstack-simulator-usage`
- Verify MySQL is running: `docker exec -it cloudstack-simulator-usage supervisorctl status mysqld`
- The management server takes 2-3 minutes to fully start

### Usage server keeps restarting
- This is **normal** during initial startup — it retries until the management server is ready
- supervisord retries up to 10 times with 30-second delays
- Check: `docker exec -it cloudstack-simulator-usage supervisorctl status cloudstack-usage`

### Usage records are empty
- Wait at least 5 minutes (default aggregation interval) after creating resources
- Manually trigger: `curl "http://localhost:8096/client/api?command=generateUsageRecords&domainid=1&response=json"`
- Ensure you deployed a datacenter AND created resources (VMs, IPs, volumes)

### Port already in use
```bash
# Check what's using port 8080
netstat -ano | findstr :8080

# Use different ports
docker-compose run -p 9080:8080 -p 9096:8096 cloudstack-simulator
```

### Build fails with out of memory
- Increase Docker memory to at least 8 GB (Docker Desktop > Settings > Resources)
- Maven builds are memory-intensive

---

## References

- [CloudStack Usage Docs](https://docs.cloudstack.apache.org/en/latest/adminguide/usage.html)
- [CloudStack Usage Service Deep Dive (ShapeBlue)](https://www.shapeblue.com/cloudstack-usage-service-deep-dive/)
- [Official Simulator Image](https://hub.docker.com/r/apache/cloudstack-simulator)
- [CloudStack GitHub](https://github.com/apache/cloudstack)

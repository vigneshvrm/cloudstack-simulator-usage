# CloudStack Simulator with Usage Service

An enhanced Apache CloudStack simulator Docker image that adds the **Usage Service** for billing, metering, and resource consumption testing.

## The Problem

The official `apache/cloudstack-simulator` Docker image runs 3 services:
- **MySQL** — database
- **Management Server** — the CloudStack API and backend
- **UI** — the web interface

It does **not** run the **Usage Server**. This means you cannot test:
- `listUsageRecords` API
- `generateUsageRecords` API
- Billing/metering integrations
- Usage-based resource tracking (VM runtime, storage, network, IPs)

This project fixes that by adding the Usage Server as a 4th service.

---

## How It Works (The Big Picture)

We **extend** the official `apache/cloudstack-simulator` image — we don't rebuild from source or replace any of its internals. The official image already compiles the usage module and creates the `cloud_usage` database. It just doesn't run the usage process.

Our image adds exactly 4 files on top of the official image:

```
cloudstack-simulator-usage/
├── Dockerfile                        # Extends official image, adds 4 files
├── cloudstack-usage.conf             # Tells supervisord to run our usage service
├── conf/
│   └── db.properties                 # Isolated database config with small connection pools
├── scripts/
│   ├── start-usage.sh                # Startup script: wait → configure → start Java
│   └── systemctl-wrapper.sh          # Makes the UI show "Up" instead of "Down"
├── docker-compose.yml                # Easy deployment
└── README.md
```

The official image's supervisord is configured to auto-load any `.conf` files from `/etc/supervisor/conf.d/`. We simply drop our `cloudstack-usage.conf` into that directory, and supervisord picks it up automatically alongside the existing 3 services. **No files from the official image are modified or replaced.**

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Docker Container                                    │
│                                                      │
│  supervisord (process manager)                       │
│  ├── mysqld              ← official (untouched)      │
│  ├── cloudstack          ← official (untouched)      │
│  ├── cloudstack-ui       ← official (untouched)      │
│  └── cloudstack-usage    ← ADDED BY US               │
│                                                      │
│  Databases (all in the same MySQL instance):         │
│  ├── cloud          ← management server config/state │
│  ├── cloud_usage    ← usage records (billing data)   │
│  └── simulator      ← simulated hypervisor state     │
│                                                      │
│  Port:                                               │
│  └── 5050  → Nginx reverse proxy (UI + API)          │
└──────────────────────────────────────────────────────┘
```

---

## Every File Explained

### 1. Dockerfile — The Image Definition

```dockerfile
ARG CS_VERSION=4.20.1.0
FROM apache/cloudstack-simulator:${CS_VERSION}
```

We start from the official simulator image. The `CS_VERSION` build argument lets you build for any CloudStack release (4.20.1.0, 4.19.1.0, etc.).

```dockerfile
RUN cd /root && mvn -pl usage dependency:build-classpath -q \
    -DincludeScope=runtime -Dmdep.outputFile=/tmp/usage-cp.txt
```

**What this does:** The usage server is a Java application. Java needs to know where all its dependency JARs are (the "classpath"). This Maven command resolves all the JARs that the usage module needs and writes their paths to `/tmp/usage-cp.txt`. We do this at **build time** so the container doesn't need Maven at runtime.

```dockerfile
RUN find /root -name "db.properties" -exec sed -i \
      -e 's/db.cloud.maxActive=.*/db.cloud.maxActive=50/' \
      -e 's/db.usage.maxActive=.*/db.usage.maxActive=20/' \
      -e 's/db.simulator.maxActive=.*/db.simulator.maxActive=20/' \
    {} \; 2>/dev/null || true
```

**What this does:** Reduces the **management server's** connection pool sizes from the production defaults (250+100+250=600) down to container-friendly sizes (50+20+20=90). The production defaults are designed for bare-metal servers, not Docker containers sharing a single MySQL instance. Without this, the management server's pools compete with the usage server's pools and exhaust MySQL's connection limit.

```dockerfile
RUN mkdir -p /etc/cloudstack/usage/conf
COPY conf/db.properties /etc/cloudstack/usage/db.properties
COPY conf/db.properties /etc/cloudstack/usage/conf/db.properties
```

**What this does:** Gives the usage server its own database configuration file with even smaller pools (5+10+2=17). Copied to both root and `conf/` subdirectory so CloudStack's `PropertiesUtil` finds it regardless of which search path it uses.

```dockerfile
RUN cp /root/utils/conf/log4j-cloud.xml /etc/cloudstack/usage/log4j-cloud.xml 2>/dev/null || true
```

**What this does:** Copies the logging configuration so the usage server can write structured logs.

```dockerfile
COPY cloudstack-usage.conf /etc/supervisor/conf.d/cloudstack-usage.conf
COPY scripts/start-usage.sh /usr/local/bin/start-usage.sh
RUN chmod +x /usr/local/bin/start-usage.sh
```

**What this does:** Adds the supervisord config that tells the process manager to run our startup script. Supervisord auto-loads any `.conf` files from `conf.d/`.

```dockerfile
COPY scripts/systemctl-wrapper.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl
```

**What this does:** Installs a fake `systemctl` command that bridges the gap between supervisord (what containers use) and systemd (what CloudStack expects). Without this, the UI shows the usage server as "Down" even when it's running (see "Problems We Solved" below).

**Important:** There is no `CMD` or `ENTRYPOINT` override. The official image's startup command (`/usr/bin/supervisord`) runs as-is.

---

### 2. scripts/start-usage.sh — The Startup Script

This is the brain of the operation. It runs inside the container when supervisord starts the `cloudstack-usage` program. Here's what each section does:

**Step 1 — Wait for MySQL:**
```bash
until mysqladmin ping --silent 2>/dev/null; do sleep 2; done
```
The usage server needs MySQL to be fully up before it can connect. This loops every 2 seconds until MySQL responds.

**Step 2 — Increase MySQL connection limit:**
```bash
mysql -e "SET GLOBAL max_connections = 350;" 2>/dev/null || true
```
MySQL's default limit is 151 connections. Both the management server and usage server create connection pools for 3 databases each. 151 is not enough for two Java processes — increasing to 350 gives both processes room to operate (see "Problems We Solved" below).

**Step 3 — Wait for the Management Server API:**
```bash
until curl -sf "http://localhost:8096/client/api?command=listZones&response=json" >/dev/null 2>&1; do
  sleep 5
done
```
The management server takes 2-3 minutes to fully start. We can't apply configuration or start the usage server until it's ready. This loops every 5 seconds until the API responds.

**Step 4 — Apply usage configuration via API:**
```bash
curl -sf "http://localhost:8096/client/api?command=updateConfiguration&name=enable.usage.server&value=true&response=json"
curl -sf "http://localhost:8096/client/api?command=updateConfiguration&name=usage.stats.job.aggregation.range&value=${RANGE}&response=json"
curl -sf "http://localhost:8096/client/api?command=updateConfiguration&name=usage.stats.job.exec.time&value=00:00&response=json"
```
These API calls enable the usage server and configure how often it aggregates usage data (default: every 5 minutes). Using the API ensures the configuration is applied correctly even when the database is persisted across container restarts.

**Step 5 — Start the Usage Server:**
```bash
exec java -Xms128m -Xmx512m \
  -Dcatalina.home=/etc/cloudstack/usage \
  -cp /etc/cloudstack/usage:/root/usage/target/classes:/root/usage/target/transformed:$(cat /tmp/usage-cp.txt) \
  com.cloud.usage.UsageServer
```
This starts the actual Java process:
- `-Xms128m -Xmx512m` — limits memory usage (128 MB initial, 512 MB max)
- `-Dcatalina.home=/etc/cloudstack/usage` — tells CloudStack to look for config files in our isolated directory
- `-cp ...` — the Java classpath, with our `/etc/cloudstack/usage` directory **first** so Java finds our small `db.properties` before any others
- `com.cloud.usage.UsageServer` — the main class that runs the usage server

The `exec` replaces the shell process with Java, so supervisord can properly manage (stop/restart) the process.

---

### 3. conf/db.properties — Isolated Database Configuration

In a normal CloudStack deployment, the management server and usage server share the same `db.properties`. But in a single container, this causes a problem: both processes create connection pools for all 3 databases, and the combined total overwhelms MySQL.

Our solution has two parts: reduce the management server's pools (via `sed` in Dockerfile) AND give the usage server its **own** even smaller pools:

| Database | Original Default | Mgmt Server (Patched) | Usage Server (Ours) |
|----------|-----------------|----------------------|---------------------|
| `cloud` | 250 | **50** | **5** |
| `cloud_usage` | 100 | **20** | **10** |
| `simulator` | 250 | **20** | **2** |
| **Total** | **600** | **90** | **17** |

Combined (90 + 17 = 107), well within MySQL's 350 `max_connections` limit.

The usage server doesn't need large pools — it runs batch jobs every few minutes, not real-time API requests. These small pools are more than enough while keeping MySQL healthy.

---

### 4. cloudstack-usage.conf — Supervisord Program Config

```ini
[program:cloudstack-usage]
command=/usr/local/bin/start-usage.sh
autostart=true
autorestart=true
startsecs=10
startretries=10
```

This tells supervisord:
- **autostart=true** — start the usage server when the container starts
- **autorestart=true** — restart it if it crashes
- **startsecs=10** — the process must stay running for 10 seconds to be considered "started"
- **startretries=10** — try up to 10 times if it fails to start (useful during initial startup when MySQL/management server aren't ready yet)

---

### 5. scripts/systemctl-wrapper.sh — UI Status Fix

CloudStack's web UI checks whether the usage server is running by executing:
```bash
systemctl status cloudstack-usage | grep "  Active:"
```

This works on normal servers (which use systemd), but Docker containers use **supervisord** instead. Without this wrapper, the UI always shows the usage server as "Down" even when it's actually running.

Our wrapper intercepts `systemctl status cloudstack-usage` calls and translates them to `supervisorctl status cloudstack-usage`:
- If supervisord says `RUNNING` → outputs `Active: active (running)` (exit code 0)
- Otherwise → outputs `Active: inactive (dead)` (exit code 3)

All other `systemctl` calls are passed through to the real binary if it exists.

---

### 6. docker-compose.yml — Deployment Configuration

Defines how to build and run the container:
- **Port:** Maps host 8080 to container's internal Nginx on 5050 (serves both UI and API)
- **Environment:** `USAGE_AGGREGATION_RANGE` controls how often usage data is aggregated (default: 5 minutes)
- **Volume:** `db-data` persists MySQL data across container restarts
- **Healthcheck:** Polls the API every 30 seconds to monitor container health
- **Version:** Configurable via `CS_VERSION` environment variable

---

## Problems We Solved (and How)

Building this was not straightforward. Here are the real problems we hit and how we fixed each one.

### Problem 1: Building From Source Was Too Heavy

**Symptom:** Our first version cloned the entire CloudStack repo and built from source. This took 15-30+ minutes, used 15+ GB of disk, and required 8+ GB of RAM.

**Root cause:** We were doing way more work than necessary. The official `apache/cloudstack-simulator` image already has everything compiled — the usage module, the `cloud_usage` database, all the JARs.

**Solution:** We switched to **extending** the official image instead of rebuilding from source. Our Dockerfile is now 30 lines. Build time dropped from 30+ minutes to ~2 minutes (mostly just the Maven classpath resolution). We don't replace any files from the official image — we only add new ones.

---

### Problem 2: Usage Server Not Starting (Classpath Issues)

**Symptom:** The usage server process would crash immediately with `ClassNotFoundException` errors.

**Root cause:** The usage server is a standalone Java application (`com.cloud.usage.UsageServer`). It needs the correct classpath to find all its dependencies. The official image compiles everything but doesn't set up the classpath for running the usage server independently.

**Solution:** At Docker build time, we run `mvn -pl usage dependency:build-classpath` to resolve all dependency JAR paths and save them to `/tmp/usage-cp.txt`. At runtime, we construct the Java classpath from this file plus the compiled usage classes at `/root/usage/target/classes` and `/root/usage/target/transformed` (Spring-transformed classes).

---

### Problem 3: Configuration Null Errors

**Symptom:** The usage server would start but crash with errors like `usage.stats.job.exec.time = null`.

**Root cause:** We were initially applying configuration via SQL directly to the database. But the management server initializes the database schema and populates the `configuration` table during its own startup. If we ran SQL before the management server finished starting, the configuration table was empty or incomplete.

**Solution:** Instead of direct SQL, we now:
1. Wait for the management server API to be fully responsive (by polling `listZones`)
2. Apply configuration via the CloudStack API (`updateConfiguration`)

This guarantees the database is fully initialized before we touch it. It's also idempotent — safe to run on every container restart, even with persistent volumes.

---

### Problem 4: Database Connection Pool Exhaustion (Can't Login)

**Symptom:** After the usage server started, the management server would stop responding. Login attempts failed with:
```
Connection is not available, request timed out after 30000ms
(total=6, active=6, idle=0, waiting=19)
```
Stopping the usage server **immediately** fixed the problem.

**Root cause:** This was the hardest bug. CloudStack uses HikariCP connection pools. Every Java process (management server AND usage server) creates connection pools for **all 3 databases** (cloud, cloud_usage, simulator) via a static initializer in `TransactionLegacy.java`.

The management server's default pool sizes are: cloud=250 + usage=100 + simulator=250 = **600 connections max**.

MySQL's default `max_connections` is only **151**.

When both processes tried to grow their pools under load, MySQL hit its connection limit. The management server's pool got stuck at just 6 connections and couldn't grow, causing every API request to time out waiting for a free connection.

**Solution (three parts):**
1. **Reduce management server pools** — At build time, we `sed` all `db.properties` files to reduce pool sizes from 600 to 90 (50+20+20). The production defaults are designed for bare-metal servers, not containers.
2. **Isolated db.properties for usage server** — We give the usage server its own `db.properties` with even tinier pools (5 + 10 + 2 = 17 total connections).
3. **Increase MySQL max_connections** — We raise MySQL's connection limit from 151 to 350 at startup (`SET GLOBAL max_connections = 350`). Combined total (90 + 17 = 107) is well within 350.

---

### Problem 5: Usage Server Shows "Down" in UI

**Symptom:** The usage server was running (confirmed via `supervisorctl status`), heartbeats were being written to the database, but the CloudStack UI showed "Usage Server: Down".

**Root cause:** CloudStack's `MetricsServiceImpl.isUsageRunning()` method checks the usage server status by running:
```bash
systemctl status cloudstack-usage
```
and looking for the string `Active:` in the output. Docker containers use supervisord, not systemd, so this command fails silently and the UI always reports "Down".

**Solution:** We install a `systemctl` wrapper script at `/usr/local/bin/systemctl` that intercepts `systemctl status cloudstack-usage` calls and translates them to supervisord queries. When supervisord says the process is `RUNNING`, the wrapper outputs the exact string CloudStack expects: `Active: active (running)`.

---

## Quick Start

### Prerequisites

- Docker Engine 20.10+ (or Podman)
- Docker Compose v2+
- Internet access (to pull the official simulator image)

### Build and Run

```bash
# Clone the repo
git clone https://github.com/vigneshvrm/cloudstack-simulator-usage.git
cd cloudstack-simulator-usage

# Build and start (default: CloudStack 4.20.1.0)
docker-compose build
docker-compose up -d

# Or build a specific version
CS_VERSION=4.19.1.0 docker-compose build
CS_VERSION=4.19.1.0 docker-compose up -d
```

### Using Podman (e.g., on a VM without Docker)

```bash
# Pull pre-built image
sudo podman pull registry.assistanz24x7.com:4443/stackbill/cloudstack-simulator-usage:4.20.1.0

# Run
sudo podman run -d --name cloudstack-simulator-usage \
  -p 8080:5050 \
  -e USAGE_AGGREGATION_RANGE=5 \
  --restart unless-stopped \
  registry.assistanz24x7.com:4443/stackbill/cloudstack-simulator-usage:4.20.1.0
```

### Wait for Startup (~3-4 minutes)

```bash
docker logs -f cloudstack-simulator-usage
```

Look for these log messages in order:
1. `mysqld is alive` — MySQL is ready
2. `[usage] MySQL max_connections raised to 350` — DB tuned for dual-process operation
3. `[usage] Management server API is ready` — CloudStack API is up
4. `[usage] Config applied via API` — Usage settings configured
5. `[usage] Starting UsageServer...` — Usage server launching

### Verify All 4 Services

```bash
docker exec cloudstack-simulator-usage supervisorctl status
```

Expected:
```
cloudstack          RUNNING   pid 123, uptime 0:05:00
cloudstack-ui       RUNNING   pid 456, uptime 0:04:30
cloudstack-usage    RUNNING   pid 789, uptime 0:02:00
mysqld              RUNNING   pid 100, uptime 0:05:30
```

### Access the UI

Open **http://localhost:8080** (or `http://<VM-IP>:8080` for remote VMs)

Login: **admin** / **password**

The Infrastructure page should show Usage Server status as **Up**.

---

## Testing Usage Records

### Step 1: Deploy a Zone

```bash
docker exec cloudstack-simulator-usage \
  python /root/tools/marvin/marvin/deployDataCenter.py \
  -i /root/setup/dev/advanced.cfg
```

Wait ~2 minutes for system VMs to start.

Available zone configurations:

| Config File | Zone Type |
|-------------|-----------|
| `advanced.cfg` | Advanced zone (no security groups) — **recommended** |
| `advancedsg.cfg` | Advanced zone with security groups |
| `basic.cfg` | Basic zone |

### Step 2: Create a VM

```bash
# Get IDs for deployment (using internal API port via docker exec)
OFFERING=$(docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listServiceOfferings&response=json" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['listserviceofferingsresponse']['serviceoffering'][0]['id'])")

TEMPLATE=$(docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listTemplates&templatefilter=all&response=json" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['listtemplatesresponse']['template'][0]['id'])")

ZONE=$(docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listZones&response=json" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['listzonesresponse']['zone'][0]['id'])")

# Deploy
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=deployVirtualMachine&serviceofferingid=${OFFERING}&templateid=${TEMPLATE}&zoneid=${ZONE}&response=json" | python3 -m json.tool
```

### Step 3: View Usage Records

Wait 5 minutes (default aggregation interval), or trigger manually:

```bash
# Trigger usage generation
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=generateUsageRecords&domainid=1&response=json"

# List records
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listUsageRecords&domainid=1&response=json" | python3 -m json.tool
```

You should see records for RUNNING_VM, ALLOCATED_VM, VOLUME, TEMPLATE, etc.

---

## Configuration

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `CS_VERSION` | `4.20.1.0` | CloudStack release tag to use |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USAGE_AGGREGATION_RANGE` | `5` | Usage aggregation interval in minutes. Lower = faster record generation for testing. Production default is 1440 (daily). |

### Port

| Host | Container | Service |
|------|-----------|---------|
| 8080 | 5050 | CloudStack UI + API (Nginx reverse proxy) |

### Usage Types Tracked

| ID | Type | What It Measures |
|----|------|------------------|
| 1 | RUNNING_VM | VM running time |
| 2 | ALLOCATED_VM | VM lifecycle (create to destroy) |
| 3 | IP_ADDRESS | Public IP ownership |
| 4 | NETWORK_BYTES_SENT | Outbound network traffic |
| 5 | NETWORK_BYTES_RECEIVED | Inbound network traffic |
| 6 | VOLUME | Disk volume lifecycle |
| 7 | TEMPLATE | Template storage |
| 8 | ISO | ISO file usage |
| 9 | SNAPSHOT | Snapshot lifecycle |
| 11 | LOAD_BALANCER_POLICY | LB policy lifecycle |
| 12 | PORT_FORWARDING_RULE | Port forwarding rule lifecycle |
| 13 | NETWORK_OFFERING | Network offering assignment |
| 14 | VPN_USERS | VPN user lifecycle |

---

## Common Operations

```bash
# View live logs
docker logs -f cloudstack-simulator-usage

# View usage server logs only
docker exec cloudstack-simulator-usage supervisorctl tail -f cloudstack-usage

# Restart just the usage server
docker exec cloudstack-simulator-usage supervisorctl restart cloudstack-usage

# Check usage config
docker exec cloudstack-simulator-usage curl -s "http://localhost:8096/client/api?command=listConfigurations&name=enable.usage.server&response=json" | python3 -m json.tool

# Check MySQL connection status
docker exec cloudstack-simulator-usage mysql -e "SELECT @@max_connections; SHOW STATUS LIKE 'Threads_connected';"

# Stop container (keeps data)
docker-compose down

# Stop and delete all data (fresh start)
docker-compose down -v

# Rebuild with no cache (after changing files)
docker-compose build --no-cache

# Shell into the container
docker exec -it cloudstack-simulator-usage bash
```

---

## Troubleshooting

### Can't login / API not responding after usage server starts
- This usually means MySQL connection exhaustion. Check: `docker exec cloudstack-simulator-usage mysql -e "SELECT @@max_connections;"`
- If it shows 151 (not 350), the usage startup script failed before raising the limit. Restart: `docker exec cloudstack-simulator-usage supervisorctl restart cloudstack-usage`
- Verify all services: `docker exec cloudstack-simulator-usage supervisorctl status`

### Usage server keeps restarting
- This is **normal** during the first 3-4 minutes — it retries until MySQL and the management server are ready
- supervisord retries up to 10 times
- Check: `docker exec cloudstack-simulator-usage supervisorctl tail cloudstack-usage`

### Usage records are empty
- Wait at least 5 minutes after creating resources (VMs, volumes, etc.)
- Manually trigger: `docker exec cloudstack-simulator-usage curl "http://localhost:8096/client/api?command=generateUsageRecords&domainid=1&response=json"`
- Ensure you've deployed a zone AND created resources

### Usage server shows "Down" in UI
- Verify wrapper is installed: `docker exec cloudstack-simulator-usage which systemctl`
- Test it: `docker exec cloudstack-simulator-usage systemctl status cloudstack-usage`
- Should show `Active: active (running)`

---

## Project Evolution

This project went through several iterations to reach its current minimal form:

| Version | Approach | Issue |
|---------|----------|-------|
| v1 | Build CloudStack from source | 30+ min build, 15 GB disk, fragile |
| v2 | Extend official image, replace supervisord.conf | Too invasive, broke official startup |
| v3 | Drop-in conf.d file, direct SQL config | Config null errors (DB not ready) |
| v4 | API-based config, isolated usage db.properties | DB connection pool exhaustion (mgmt server pools too large) |
| v5 | MySQL max_connections=800 | Thread/process limit exhaustion (too many threads) |
| **v6 (current)** | **Reduce mgmt server pools + isolated usage db.properties + MySQL tuning** | **Working** |

---

## References

- [CloudStack Usage Docs](https://docs.cloudstack.apache.org/en/latest/adminguide/usage.html)
- [CloudStack Usage Service Deep Dive (ShapeBlue)](https://www.shapeblue.com/cloudstack-usage-service-deep-dive/)
- [Official Simulator Image](https://hub.docker.com/r/apache/cloudstack-simulator)
- [CloudStack Source Code](https://github.com/apache/cloudstack)
- [Harbor: stackbill/cloudstack-simulator-usage](https://registry.assistanz24x7.com:4443/harbor/projects)
- [Docker Hub: vickyinfra/cloudstack-simulator-usage](https://hub.docker.com/r/vickyinfra/cloudstack-simulator-usage)
- [GitHub: vigneshvrm/cloudstack-simulator-usage](https://github.com/vigneshvrm/cloudstack-simulator-usage)

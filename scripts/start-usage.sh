#!/bin/bash
# CloudStack Usage Server startup script
# Waits for management server to be ready, applies config, starts Java with isolated DB pool

echo "[usage] Waiting for MySQL..."
until mysqladmin ping --silent 2>/dev/null; do sleep 2; done
echo "[usage] MySQL is ready"

# CRITICAL: Increase MySQL max_connections for dual-process operation
# Default max_connections=151 is too low when both management server and usage server
# create HikariCP connection pools for 3 databases each (cloud, cloud_usage, simulator).
# Without this, MySQL rejects new connections and the management server's pool starves.
mysql -e "SET GLOBAL max_connections = 350;" 2>/dev/null || true
echo "[usage] MySQL max_connections raised to 350"

# Wait for management server API to be fully responsive
# This ensures DB initialization is complete and configuration table is populated
echo "[usage] Waiting for management server API..."
until curl -sf "http://localhost:8096/client/api?command=listZones&response=json" >/dev/null 2>&1; do
  sleep 5
done
echo "[usage] Management server API is ready"

# Apply usage config via CloudStack API (idempotent — safe on every restart)
RANGE="${USAGE_AGGREGATION_RANGE:-5}"
curl -sf "http://localhost:8096/client/api?command=updateConfiguration&name=enable.usage.server&value=true&response=json" >/dev/null 2>&1
curl -sf "http://localhost:8096/client/api?command=updateConfiguration&name=usage.stats.job.aggregation.range&value=${RANGE}&response=json" >/dev/null 2>&1
curl -sf "http://localhost:8096/client/api?command=updateConfiguration&name=usage.stats.job.exec.time&value=00:00&response=json" >/dev/null 2>&1
echo "[usage] Config applied via API (aggregation_range=${RANGE} min)"

# Start usage server via Java with ISOLATED db.properties (small connection pools)
# The usage server gets its own db.properties at /etc/cloudstack/usage/ with:
#   cloud pool: maxActive=5 (vs management server's 250)
#   usage pool: maxActive=10 (vs management server's 100)
#   simulator pool: maxActive=2 (vs management server's 250)
# This prevents the usage server from overwhelming MySQL in the container.
echo "[usage] Starting UsageServer..."
exec java -Xms128m -Xmx512m \
  -Dcatalina.home=/etc/cloudstack/usage \
  -cp "/etc/cloudstack/usage:/root/usage/target/classes:/root/usage/target/transformed:$(cat /tmp/usage-cp.txt):/root/client/target/lib/*" \
  com.cloud.usage.UsageServer

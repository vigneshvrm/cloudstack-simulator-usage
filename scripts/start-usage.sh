#!/bin/bash
# CloudStack Usage Server startup script
# Waits for MySQL, applies config, starts Java directly (no Maven overhead)

echo "[usage] Waiting for MySQL..."
until mysqladmin ping --silent 2>/dev/null; do sleep 2; done
echo "[usage] MySQL is ready"

# Ensure usage config is set (idempotent — safe on every restart)
RANGE="${USAGE_AGGREGATION_RANGE:-5}"
mysql -e "
USE cloud;
UPDATE configuration SET value='true' WHERE name='enable.usage.server';
UPDATE configuration SET value='${RANGE}' WHERE name='usage.stats.job.aggregation.range';
UPDATE configuration SET value='00:00' WHERE name='usage.stats.job.exec.time';
" 2>/dev/null || true
echo "[usage] Config applied (aggregation_range=${RANGE} min)"

# Start usage server via Java (classpath pre-built at image build time)
echo "[usage] Starting UsageServer..."
exec java -Dcatalina.home=/root/utils \
  -cp /root/usage/target/classes:/root/usage/target/transformed:$(cat /tmp/usage-cp.txt) \
  com.cloud.usage.UsageServer

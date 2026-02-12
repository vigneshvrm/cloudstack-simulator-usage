#!/bin/bash
# Entrypoint script for CloudStack Simulator with Usage Service
# Ensures usage server config is always applied, even with persistent volumes.

set -e

AGGREGATION_RANGE="${USAGE_AGGREGATION_RANGE:-5}"

echo "[entrypoint] Applying usage server configuration..."

# Start MySQL temporarily to apply config
/usr/bin/mysqld_safe &
MYSQL_PID=$!

# Wait for MySQL to be ready
for i in $(seq 1 30); do
    if mysqladmin ping --silent 2>/dev/null; then
        break
    fi
    echo "[entrypoint] Waiting for MySQL... ($i/30)"
    sleep 1
done

# Always ensure usage server is enabled and configured
mysql -e "
USE cloud;
UPDATE configuration SET value = 'true' WHERE name = 'enable.usage.server';
UPDATE configuration SET value = '${AGGREGATION_RANGE}' WHERE name = 'usage.stats.job.aggregation.range';
UPDATE configuration SET value = '00:00' WHERE name = 'usage.stats.job.exec.time';
" 2>/dev/null || true

echo "[entrypoint] Usage config applied (aggregation_range=${AGGREGATION_RANGE})"

# Stop MySQL (supervisord will manage it)
mysqladmin shutdown 2>/dev/null || true
wait $MYSQL_PID 2>/dev/null || true
sleep 2

echo "[entrypoint] Starting services: MySQL, Management Server, Usage Server, UI"
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

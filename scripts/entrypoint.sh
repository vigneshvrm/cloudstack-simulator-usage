#!/bin/bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.
#
# Entrypoint script for CloudStack Simulator with Usage Service
# Ensures proper startup ordering: MySQL → Management Server → Usage Server → UI

set -e

# ── Runtime configuration overrides ──────────────────────────────────
# Allow overriding usage aggregation range at container startup
if [ -n "$USAGE_AGGREGATION_RANGE" ]; then
    echo "[entrypoint] Setting usage.stats.job.aggregation.range = ${USAGE_AGGREGATION_RANGE}"
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

    mysql -e "USE cloud; UPDATE configuration SET value = '${USAGE_AGGREGATION_RANGE}' WHERE name = 'usage.stats.job.aggregation.range';" 2>/dev/null || true

    # Stop MySQL (supervisord will manage it)
    mysqladmin shutdown 2>/dev/null || true
    wait $MYSQL_PID 2>/dev/null || true
    sleep 2
fi

echo "[entrypoint] Starting CloudStack Simulator with Usage Service via supervisord..."
echo "[entrypoint] Services: MySQL, Management Server, Usage Server, UI"

# Hand off to supervisord which manages all 4 services
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

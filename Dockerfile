# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Extend the official CloudStack simulator image.
# The official image already compiles the usage module and creates the
# cloud_usage database — only the runtime process and config are missing.
ARG CS_VERSION=4.20.1.0
FROM apache/cloudstack-simulator:${CS_VERSION}

LABEL org.opencontainers.image.title="CloudStack Simulator with Usage Service"
LABEL org.opencontainers.image.description="Apache CloudStack Simulator with integrated Usage Service for billing/metering testing"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# ── Enable usage server in the database ────────────────────────────────
COPY setup-usage.sql /tmp/setup-usage.sql

RUN find /var/lib/mysql -type f -exec touch {} \; \
    && (/usr/bin/mysqld_safe &) \
    && sleep 5 \
    && until mysqladmin ping --silent 2>/dev/null; do sleep 1; done \
    && mysql < /tmp/setup-usage.sql \
    && mysqladmin shutdown \
    && rm /tmp/setup-usage.sql

# ── Replace supervisord config with our 4-service version ─────────────
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ── Add entrypoint for runtime config overrides ───────────────────────
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080 8096 5050

CMD ["/entrypoint.sh"]

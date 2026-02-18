# Minimal extension of the official CloudStack simulator.
# Adds ONLY the Usage Service — everything else stays untouched.
ARG CS_VERSION=4.20.1.0
FROM apache/cloudstack-simulator:${CS_VERSION}

LABEL org.opencontainers.image.title="CloudStack Simulator with Usage Service"
LABEL org.opencontainers.image.description="Official CloudStack Simulator + Usage Service for billing/metering"

# Pre-build usage server classpath (avoids Maven at runtime)
RUN cd /root && mvn -pl usage dependency:build-classpath -q \
    -DincludeScope=runtime -Dmdep.outputFile=/tmp/usage-cp.txt

# CRITICAL: Reduce management server pool sizes for container environment.
# Default pool sizes (250+100+250=600) are designed for production servers, not containers.
# In a single container with MySQL max_connections=350, both the management server and
# usage server compete for connections. Reducing to 50+20+20=90 prevents exhaustion.
RUN find /root -name "db.properties" -exec sed -i \
      -e 's/db.cloud.maxActive=.*/db.cloud.maxActive=50/' \
      -e 's/db.usage.maxActive=.*/db.usage.maxActive=20/' \
      -e 's/db.simulator.maxActive=.*/db.simulator.maxActive=20/' \
    {} \; 2>/dev/null || true

# Usage server gets its own db.properties with even smaller connection pools
# Copy to both root and conf/ so PropertiesUtil finds it regardless of search path
RUN mkdir -p /etc/cloudstack/usage/conf
COPY conf/db.properties /etc/cloudstack/usage/db.properties
COPY conf/db.properties /etc/cloudstack/usage/conf/db.properties

# Copy log4j config from management server (usage server needs it)
RUN cp /root/utils/conf/log4j-cloud.xml /etc/cloudstack/usage/log4j-cloud.xml 2>/dev/null || true

# Add usage service — supervisord auto-loads conf.d/*.conf
COPY cloudstack-usage.conf /etc/supervisor/conf.d/cloudstack-usage.conf
COPY scripts/start-usage.sh /usr/local/bin/start-usage.sh
RUN chmod +x /usr/local/bin/start-usage.sh

# Fix "Down" state in UI: CloudStack checks "systemctl status cloudstack-usage"
# but containers use supervisord, not systemd. This wrapper bridges the gap.
COPY scripts/systemctl-wrapper.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

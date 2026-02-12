# Minimal extension of the official CloudStack simulator.
# Adds ONLY the Usage Service — everything else stays untouched.
ARG CS_VERSION=4.20.1.0
FROM apache/cloudstack-simulator:${CS_VERSION}

LABEL org.opencontainers.image.title="CloudStack Simulator with Usage Service"
LABEL org.opencontainers.image.description="Official CloudStack Simulator + Usage Service for billing/metering"

# Pre-build usage server classpath (avoids Maven at runtime)
RUN cd /root && mvn -pl usage dependency:build-classpath -q \
    -DincludeScope=runtime -Dmdep.outputFile=/tmp/usage-cp.txt

# Add usage service — supervisord auto-loads conf.d/*.conf
COPY cloudstack-usage.conf /etc/supervisor/conf.d/cloudstack-usage.conf
COPY scripts/start-usage.sh /usr/local/bin/start-usage.sh
RUN chmod +x /usr/local/bin/start-usage.sh

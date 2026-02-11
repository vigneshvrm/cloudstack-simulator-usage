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

FROM ubuntu:22.04

LABEL org.opencontainers.image.title="CloudStack Simulator with Usage Service"
LABEL org.opencontainers.image.description="Apache CloudStack Simulator with integrated Usage Service for billing/metering testing"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# ── Configurable build arguments ──────────────────────────────────────
ARG CS_VERSION=4.20.1.0
ARG CS_REPO=https://github.com/apache/cloudstack.git
ARG USAGE_AGGREGATION_RANGE=5

ENV DEBIAN_FRONTEND=noninteractive

# ── Install system dependencies ───────────────────────────────────────
RUN apt-get -y update && apt-get install -y \
    genisoimage \
    libffi-dev \
    libssl-dev \
    curl \
    gcc-10 \
    git \
    sudo \
    ipmitool \
    iproute2 \
    maven \
    openjdk-11-jdk \
    python3-dev \
    python-is-python3 \
    python3-setuptools \
    python3-pip \
    python3-mysql.connector \
    supervisor \
    && apt-get clean all

# ── Install MySQL ─────────────────────────────────────────────────────
RUN apt-get install -qqy mysql-server \
    && apt-get clean all \
    && mkdir -p /var/run/mysqld \
    && chown mysql /var/run/mysqld

# Configure MySQL SQL mode
RUN echo 'sql_mode = "STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"' \
    >> /etc/mysql/mysql.conf.d/mysqld.cnf

# ── Clone CloudStack source at specified version ──────────────────────
RUN git clone --depth 1 --branch ${CS_VERSION} ${CS_REPO} /root/cloudstack

WORKDIR /root/cloudstack

# ── Build CloudStack with simulator (includes usage module) ──────────
RUN mvn -Pdeveloper -Dsimulator -DskipTests clean install

# ── Deploy databases (cloud + cloud_usage) and install Marvin ────────
COPY setup-usage.sql /tmp/setup-usage.sql

RUN find /var/lib/mysql -type f -exec touch {} \; \
    && (/usr/bin/mysqld_safe &) \
    && sleep 5 \
    && mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password by ''" --connect-expired-password \
    && mvn -Pdeveloper -pl developer -Ddeploydb \
    && mvn -Pdeveloper -pl developer -Ddeploydb-simulator \
    # Enable usage server and configure aggregation range
    && mysql < /tmp/setup-usage.sql \
    && rm /tmp/setup-usage.sql \
    # Install Marvin testing framework
    && MARVIN_FILE=$(find /root/cloudstack/tools/marvin/dist/ -name "Marvin*.tar.gz") \
    && rm -rf /usr/bin/x86_64-linux-gnu-gcc \
    && ln -s /usr/bin/gcc-10 /usr/bin/x86_64-linux-gnu-gcc \
    && pip3 install $MARVIN_FILE

# ── Install Node.js and build UI ─────────────────────────────────────
RUN curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash - \
    && apt-get install -y nodejs \
    && cd ui \
    && npm rebuild node-sass \
    && npm install

# ── Copy configuration files ─────────────────────────────────────────
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Expose ports ─────────────────────────────────────────────────────
# 8080: CloudStack UI
# 8096: CloudStack API (unauthenticated integration port)
# 5050: Internal simulator port
EXPOSE 8080 8096 5050

VOLUME /var/lib/mysql

CMD ["/entrypoint.sh"]

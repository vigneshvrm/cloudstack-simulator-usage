#!/bin/bash
# Wrapper for systemctl in Docker containers using supervisord.
# CloudStack's MetricsServiceImpl checks "systemctl status cloudstack-usage"
# to determine if the usage server is running. This bridges supervisord → systemctl.

if [ "$1" = "status" ] && [ "$2" = "cloudstack-usage" ]; then
  STATUS=$(supervisorctl status cloudstack-usage 2>/dev/null)
  if echo "$STATUS" | grep -q "RUNNING"; then
    echo "  Active: active (running)"
    exit 0
  else
    echo "  Active: inactive (dead)"
    exit 3
  fi
fi

# Pass through all other systemctl calls to the real binary if it exists
if [ -x /bin/systemctl ]; then
  exec /bin/systemctl "$@"
fi
exit 1

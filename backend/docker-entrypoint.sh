#!/bin/bash
set -euo pipefail
umask 077

# Create only when absent; the admin CLI must also validate any existing token.
exec-agent-admin init-token
# Keep administration and health checks on the same private endpoint. Configure the
# port through EXEC_AGENT_PORT; duplicate endpoint/profile flags fail closed.
exec exec-agent --profile /var/lib/exec/profile --workspace-tools \
    --host 127.0.0.1 --port "${EXEC_AGENT_PORT-8765}" "$@"

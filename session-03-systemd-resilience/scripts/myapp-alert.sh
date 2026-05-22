#!/usr/bin/env bash
# /usr/local/bin/myapp-alert.sh
#
# Checks the health of myapp.service and fires a Slack alert if it is not active.
# Designed to be called by cron every 5 minutes.
#
# Dependencies: curl, systemctl, journalctl
# Environment variables required:
#   SLACK_WEBHOOK_URL — Slack incoming webhook URL

set -euo pipefail
# set -e: exit immediately if any command returns a non-zero exit code
# set -u: treat unset variables as errors — prevents silent bugs
# set -o pipefail: a pipeline fails if any command in it fails, not just the last one

SERVICE="myapp.service"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"  # Read from environment, empty string if not set
HOSTNAME=$(hostname -f)                 # Fully qualified hostname for the alert message

# Check the current state of the service.
# systemctl is-active returns 'active', 'inactive', 'failed', 'activating', etc.
# The '|| true' prevents the script from exiting if the command returns non-zero
# (which it does when the service is not active).
STATE=$(systemctl is-active "$SERVICE" 2>/dev/null || true)

# Only alert if the service is not running
if [[ "$STATE" != "active" ]]; then

    # Collect the last 20 log lines to include in the alert.
    # This gives the on-call engineer immediate context without needing to SSH in.
    # --no-pager prevents journalctl from opening an interactive pager
    JOURNAL=$(journalctl -u "$SERVICE" -n 20 --no-pager 2>&1)

    # Build the Slack message.
    # Backtick formatting in Slack renders as monospace code blocks.
    MESSAGE="*ALERT* \`${SERVICE}\` on \`${HOSTNAME}\` is *${STATE}*.\n\`\`\`${JOURNAL}\`\`\`"

    # Only try to send the Slack alert if the webhook URL is configured
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -s -X POST "$SLACK_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$MESSAGE\"}"
        # -s = silent mode (no progress bar)
    fi

    # Always write to a local alert log — this is the fallback if Slack is down
    echo "$(date --iso-8601=seconds) ALERT: $SERVICE is $STATE on $HOSTNAME" \
        >> /var/log/myapp-alert.log
fi

# If STATE is 'active', the script exits here silently.
# Cron jobs should produce no output when everything is healthy —
# cron emails the owner if the script produces any stdout/stderr.

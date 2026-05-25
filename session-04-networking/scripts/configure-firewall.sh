
#!/usr/bin/env bash
# session-04-networking/scripts/configure-firewall.sh
##
# Configures ufw firewall rules for the RetailEdge EC2 instance.
# This script is IDEMPOTENT — safe to run multiple times.
# Running it again produces the same result as running it once.
#
# Usage:
#   sudo bash configure-firewall.sh OPS_IP
#
# Example:
#   sudo bash configure-firewall.sh 41.58.100.200
#
# This script is deployed and executed by GitHub Actions on every push
# to main that modifies files in session-04-networking/.

set -e

OPS_IP="${1:?Error: OPS_IP argument is required. Usage: configure-firewall.sh OPS_IP}"

echo "==> Configuring firewall for RetailEdge EC2"
echo "==> Ops IP: $OPS_IP"
echo "==> $(date --iso-8601=seconds)"

# Reset to a known-clean state
# --force skips the confirmation prompt — required for non-interactive use in CI/CD
echo "==> Resetting ufw..."
ufw --force disable
ufw --force reset

# Default policies: deny incoming, allow outgoing
echo "==> Setting default policies..."
ufw default deny incoming
ufw default allow outgoing

# Add rules in priority order
echo "==> Adding firewall rules..."

ufw allow ssh   comment "SSH access"
ufw allow http  comment "HTTP — proxied to myapp via nginx"
ufw allow https comment "HTTPS — TLS termination via nginx"

ufw allow from "$OPS_IP" to any port 9100 proto tcp \
    comment "node_exporter — ops team only"

ufw allow in on lo \
    comment "loopback — internal service communication"

# Enable — this applies rules to iptables and marks ufw for boot
echo "==> Enabling ufw..."
ufw --force enable

# Report the final state
echo "==> Configuration complete."
ufw status verbose

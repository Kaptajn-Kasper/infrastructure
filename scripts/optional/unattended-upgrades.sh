#!/bin/bash
# Configure automatic security updates via unattended-upgrades

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Unattended Upgrades Configuration"

# Install unattended-upgrades if not present
if dpkg -l unattended-upgrades &>/dev/null; then
    log_success "unattended-upgrades is already installed"
else
    log_info "Installing unattended-upgrades..."
    apt-get update -qq
    apt-get install -y -qq unattended-upgrades apt-listchanges
    log_success "unattended-upgrades installed"
fi

# Configure unattended-upgrades
CONFIG_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
log_info "Configuring unattended-upgrades..."

backup_file "$CONFIG_FILE"

cat > "$CONFIG_FILE" << 'EOF'
// Unattended Upgrades Configuration
// Only enable security updates

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Packages to never update automatically
Unattended-Upgrade::Package-Blacklist {
    // Add packages here that should not be auto-updated
    // "docker-ce";
};

// Split the upgrade into the smallest possible chunks
Unattended-Upgrade::MinimalSteps "true";

// Send email on upgrade (set to email address to enable)
// Unattended-Upgrade::Mail "admin@example.com";
// Unattended-Upgrade::MailReport "on-change";

// Remove unused kernel packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Remove new unused dependencies after upgrade
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Automatically fix interrupted dpkg
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
};

// Enable logging
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
EOF

log_success "Base configuration written"

# Configure auto-reboot if enabled
AUTO_REBOOT="${AUTO_REBOOT:-false}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-02:00}"

if [ "$AUTO_REBOOT" = "true" ]; then
    log_info "Enabling automatic reboot if required..."
    cat >> "$CONFIG_FILE" << EOF

// Automatic reboot configuration
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
EOF
    log_success "Auto-reboot enabled (at $AUTO_REBOOT_TIME if required)"
else
    cat >> "$CONFIG_FILE" << 'EOF'

// Automatic reboot is disabled
// Enable with AUTO_REBOOT=true in .env
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    log_info "Auto-reboot disabled (can be enabled with AUTO_REBOOT=true)"
fi

# Enable automatic updates
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
log_info "Enabling automatic updates..."

cat > "$AUTO_UPGRADES_FILE" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

log_success "Automatic updates enabled"

# Enable and start the service
log_info "Enabling unattended-upgrades service..."
systemctl enable unattended-upgrades
systemctl start unattended-upgrades
log_success "Service is running"

# Run a dry-run to verify configuration
log_info "Running dry-run to verify configuration..."
if unattended-upgrade --dry-run -v 2>&1 | grep -q "No packages found"; then
    log_success "Configuration verified (no pending updates)"
else
    log_success "Configuration verified"
fi

print_complete "Unattended Upgrades Configuration Complete"

echo -e "${BLUE}Unattended Upgrades:${NC}"
echo -e "  Config:      ${YELLOW}$CONFIG_FILE${NC}"
echo -e "  Status:      ${GREEN}$(systemctl is-active unattended-upgrades)${NC}"
echo -e "  Auto-reboot: ${YELLOW}$AUTO_REBOOT${NC}"
if [ "$AUTO_REBOOT" = "true" ]; then
    echo -e "  Reboot time: ${YELLOW}$AUTO_REBOOT_TIME${NC}"
fi
echo ""
echo -e "${YELLOW}Logs:${NC}"
echo -e "  /var/log/unattended-upgrades/"
echo ""
echo -e "${YELLOW}Manual run:${NC}"
echo -e "  sudo unattended-upgrade --dry-run -v"
echo ""

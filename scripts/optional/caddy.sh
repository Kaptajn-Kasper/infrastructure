#!/bin/bash
# Install Caddy reverse proxy with automatic HTTPS

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Caddy Installation"

# Check if Caddy is already installed
if command_exists caddy; then
    CADDY_VERSION=$(caddy version | head -1)
    log_success "Caddy is already installed ($CADDY_VERSION)"
else
    log_info "Installing Caddy..."

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl

    # Add Caddy GPG key
    log_info "Adding Caddy GPG key..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # Add Caddy repository
    log_info "Adding Caddy repository..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

    # Install Caddy
    apt-get update -qq
    apt-get install -y -qq caddy

    log_success "Caddy installed successfully"
fi

# Create Caddyfile if it doesn't exist
CADDYFILE="/etc/caddy/Caddyfile"
if [ ! -f "$CADDYFILE" ] || [ ! -s "$CADDYFILE" ]; then
    log_info "Creating default Caddyfile..."
    backup_file "$CADDYFILE" 2>/dev/null || true

    cat > "$CADDYFILE" << 'EOF'
# Caddy Configuration
# ====================
# Documentation: https://caddyserver.com/docs/caddyfile
#
# Example configurations:
#
# Basic reverse proxy:
# example.com {
#     reverse_proxy localhost:3000
# }
#
# With custom headers:
# api.example.com {
#     reverse_proxy localhost:8080 {
#         header_up X-Real-IP {remote_host}
#     }
# }
#
# Docker Compose app:
# app.example.com {
#     reverse_proxy app:3000
# }

# Import per-app configs from conf.d/
import /etc/caddy/conf.d/*.caddy

# Default: respond with placeholder on bare IP
:80 {
    respond "Caddy is running. Configure your domains in /etc/caddy/conf.d/"
}
EOF

    log_success "Default Caddyfile created"
else
    log_success "Caddyfile already exists"
fi

# Create Caddy config directory for includes
CADDY_CONF_DIR="/etc/caddy/conf.d"
if [ ! -d "$CADDY_CONF_DIR" ]; then
    mkdir -p "$CADDY_CONF_DIR"
    log_success "Created $CADDY_CONF_DIR for additional configs"
fi

# Ensure correct permissions
chown -R caddy:caddy /etc/caddy
chmod 644 "$CADDYFILE"

# Open firewall ports (if UFW is active)
if command_exists ufw && ufw status | grep -q "Status: active"; then
    log_info "Configuring firewall for Caddy..."
    add_ufw_rule "80" "tcp" "HTTP (Caddy)"
    add_ufw_rule "443" "tcp" "HTTPS (Caddy)"
fi

# Enable and start Caddy service
log_info "Enabling Caddy service..."
systemctl enable caddy
systemctl start caddy
log_success "Caddy service is running"

# Validate configuration
log_info "Validating Caddy configuration..."
if caddy validate --config "$CADDYFILE" &>/dev/null; then
    log_success "Caddy configuration is valid"
else
    log_warn "Caddy configuration has issues. Check with: caddy validate --config $CADDYFILE"
fi

print_complete "Caddy Installation Complete"

CADDY_VERSION=$(caddy version | head -1)
echo -e "${BLUE}Caddy:${NC}"
echo -e "  Version:    ${YELLOW}$CADDY_VERSION${NC}"
echo -e "  Config:     ${YELLOW}$CADDYFILE${NC}"
echo -e "  Status:     ${GREEN}$(systemctl is-active caddy)${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Add per-app configs to ${GREEN}$CADDY_CONF_DIR/<app>.caddy${NC}"
echo -e "  2. Reload: ${GREEN}sudo systemctl reload caddy${NC}"
echo ""
echo -e "${YELLOW}Example — ${CADDY_CONF_DIR}/myapp.caddy:${NC}"
echo -e "  myapp.example.com {"
echo -e "      reverse_proxy myapp:3000"
echo -e "  }"
echo ""

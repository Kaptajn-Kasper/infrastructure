#!/bin/bash
# Configure UFW firewall with secure defaults and rate limiting

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Firewall Configuration"

# Install UFW if not present
if ! command_exists ufw; then
    log_info "Installing UFW..."
    apt-get update -qq
    apt-get install -y -qq ufw
    log_success "UFW installed"
else
    log_success "UFW is already installed"
fi

# Check if UFW is enabled
UFW_STATUS=$(ufw status | grep -w "Status:" | awk '{print $2}')

if [ "$UFW_STATUS" = "active" ]; then
    log_success "UFW is already active"
    UFW_WAS_ACTIVE=true
else
    log_warn "UFW is currently inactive"
    UFW_WAS_ACTIVE=false
fi

log_info "Configuring firewall rules..."

# Set default policies
log_info "Setting default policies..."
ufw --force default deny incoming
ufw --force default allow outgoing
log_success "Default policies set (deny incoming, allow outgoing)"

# SSH port with rate limiting (protects against brute force)
SSH_PORT_TO_USE="${SSH_PORT:-22}"
log_info "Configuring SSH port $SSH_PORT_TO_USE with rate limiting..."

# Remove any existing SSH rules first to avoid duplicates
ufw delete allow "$SSH_PORT_TO_USE/tcp" 2>/dev/null || true
ufw delete limit "$SSH_PORT_TO_USE/tcp" 2>/dev/null || true

# Add rate-limited SSH rule
# Rate limiting: blocks IP after 6 connection attempts in 30 seconds
ufw limit "$SSH_PORT_TO_USE/tcp" comment "SSH (rate limited)"
log_success "SSH port $SSH_PORT_TO_USE configured with rate limiting"

# Allow HTTP (port 80) for web traffic and Let's Encrypt
add_ufw_rule "80" "tcp" "HTTP"

# Allow HTTPS (port 443) for secure web traffic
add_ufw_rule "443" "tcp" "HTTPS"

# Enable UFW if it wasn't already active
if [ "$UFW_WAS_ACTIVE" = false ]; then
    log_info "Enabling UFW..."
    ufw --force enable
    log_success "UFW enabled"
else
    log_info "Reloading UFW to apply changes..."
    ufw reload
    log_success "UFW reloaded"
fi

print_complete "Firewall Configuration Complete"

echo -e "${YELLOW}Current firewall rules:${NC}"
ufw status numbered
echo ""
echo -e "${GREEN}The following ports are configured:${NC}"
echo -e "  SSH:   ${YELLOW}$SSH_PORT_TO_USE${NC} (rate limited - blocks after 6 attempts in 30s)"
echo -e "  HTTP:  ${YELLOW}80${NC} (for Let's Encrypt and web traffic)"
echo -e "  HTTPS: ${YELLOW}443${NC} (for secure web traffic)"
echo ""

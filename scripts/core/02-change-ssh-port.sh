#!/bin/bash
# Change SSH port to custom port for enhanced security

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "SSH Port Configuration"

# Validate SSH_PORT
if [ -z "$SSH_PORT" ]; then
    log_error "SSH_PORT not set in .env file"
    exit 1
fi

if ! validate_port "$SSH_PORT"; then
    log_error "SSH_PORT must be a number between 1024 and 65535"
    exit 1
fi

log_info "Configuring SSH to use port $SSH_PORT"

SSHD_CONFIG="/etc/ssh/sshd_config"
CURRENT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' || echo "22")

# Check if already configured
if [ "$CURRENT_PORT" = "$SSH_PORT" ]; then
    log_success "SSH is already configured to use port $SSH_PORT"

    # Verify SSH is actually listening on the port
    if ss -tlnp | grep -q ":$SSH_PORT"; then
        log_success "SSH is listening on port $SSH_PORT"
        print_complete "SSH Port Configuration (No Changes Needed)"
        exit 0
    else
        log_warn "Port is configured but SSH is not listening. Proceeding with restart..."
    fi
fi

# Backup original sshd_config
backup_file "$SSHD_CONFIG"

# Update SSH port in sshd_config
log_info "Updating SSH port configuration..."

# Remove any existing Port lines (commented or not) and add new one
sed -i '/^#\?Port /d' "$SSHD_CONFIG"
echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

# Validate sshd configuration
log_info "Validating SSH configuration..."
if sshd -t; then
    log_success "SSH configuration is valid"
else
    log_error "SSH configuration is invalid. Restoring backup..."
    cp "${SSHD_CONFIG}.backup."* "$SSHD_CONFIG" 2>/dev/null || true
    exit 1
fi

# Update UFW firewall rules if UFW is installed and active
if command_exists ufw; then
    if ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW firewall rules..."
        add_ufw_rule "$SSH_PORT" "tcp" "SSH"
    else
        log_warn "UFW is installed but not active"
    fi
fi

# Restart SSH service
log_info "Restarting SSH service..."

# Detect the correct SSH service name
SSH_SERVICE=""
if systemctl is-active --quiet ssh 2>/dev/null || systemctl status ssh &>/dev/null; then
    SSH_SERVICE="ssh"
elif systemctl is-active --quiet sshd 2>/dev/null || systemctl status sshd &>/dev/null; then
    SSH_SERVICE="sshd"
else
    log_error "Could not find SSH service (tried ssh and sshd)"
    exit 1
fi

# Check if SSH is using socket activation
if systemctl is-active --quiet "${SSH_SERVICE}.socket" 2>/dev/null; then
    log_info "Detected socket activation. Disabling socket and enabling service..."

    # Stop and disable the socket
    systemctl stop "${SSH_SERVICE}.socket"
    systemctl disable "${SSH_SERVICE}.socket"

    # Enable and start the service directly
    systemctl enable "$SSH_SERVICE"
    systemctl restart "$SSH_SERVICE"

    log_success "SSH service ($SSH_SERVICE) now running without socket activation"
else
    # Standard service restart
    if systemctl restart "$SSH_SERVICE"; then
        log_success "SSH service ($SSH_SERVICE) restarted successfully"
    else
        log_error "Failed to restart SSH service"
        exit 1
    fi
fi

# Verify SSH is listening on new port
sleep 2
if ss -tlnp | grep -q ":$SSH_PORT"; then
    log_success "SSH is now listening on port $SSH_PORT"
else
    log_warn "Could not verify SSH is listening on port $SSH_PORT"
fi

print_complete "SSH Port Configuration Complete"

echo -e "${YELLOW}IMPORTANT:${NC}"
echo -e "1. Do NOT close this terminal session yet"
echo -e "2. Open a NEW terminal and test the connection:"
echo -e "   ${YELLOW}ssh -p $SSH_PORT user@hostname${NC}"
echo -e "3. Once verified, remove port 22 rule if needed:"
echo -e "   ${YELLOW}sudo ufw delete allow 22/tcp${NC}"
echo ""

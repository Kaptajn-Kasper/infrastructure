#!/bin/bash
# Configure system settings: timezone, swap, hostname, locale

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "System Configuration"

# ============================================
# Timezone Configuration
# ============================================

if [ "${CONFIGURE_TIMEZONE:-true}" = "true" ]; then
    log_step "Configuring Timezone"

    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")

    if [ "$CURRENT_TZ" = "UTC" ]; then
        log_success "Timezone is already set to UTC"
    else
        log_info "Setting timezone to UTC (was: $CURRENT_TZ)..."
        timedatectl set-timezone UTC
        log_success "Timezone set to UTC"
    fi
else
    log_info "Skipping timezone configuration (CONFIGURE_TIMEZONE=false)"
fi

# ============================================
# Locale Configuration
# ============================================

log_step "Configuring Locale"

# Ensure en_US.UTF-8 locale is available
if locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    log_success "en_US.UTF-8 locale is available"
else
    log_info "Generating en_US.UTF-8 locale..."
    locale-gen en_US.UTF-8 2>/dev/null || true
    update-locale LANG=en_US.UTF-8 2>/dev/null || true
    log_success "Locale configured"
fi

# ============================================
# Hostname Configuration
# ============================================

if [ -n "$SERVER_HOSTNAME" ]; then
    log_step "Configuring Hostname"

    CURRENT_HOSTNAME=$(hostname)

    if [ "$CURRENT_HOSTNAME" = "$SERVER_HOSTNAME" ]; then
        log_success "Hostname is already set to $SERVER_HOSTNAME"
    else
        log_info "Setting hostname to $SERVER_HOSTNAME (was: $CURRENT_HOSTNAME)..."
        hostnamectl set-hostname "$SERVER_HOSTNAME"

        # Update /etc/hosts if needed
        if ! grep -q "$SERVER_HOSTNAME" /etc/hosts; then
            log_info "Updating /etc/hosts..."
            echo "127.0.1.1 $SERVER_HOSTNAME" >> /etc/hosts
        fi

        log_success "Hostname set to $SERVER_HOSTNAME"
    fi
else
    log_info "Skipping hostname configuration (SERVER_HOSTNAME not set)"
fi

# ============================================
# Swap Configuration
# ============================================

if [ "${CONFIGURE_SWAP:-true}" = "true" ]; then
    log_step "Configuring Swap"

    # Check if swap already exists
    CURRENT_SWAP=$(free -m | awk '/^Swap:/ {print $2}')

    if [ "$CURRENT_SWAP" -gt 0 ]; then
        log_success "Swap is already configured (${CURRENT_SWAP}MB)"
    else
        # Get total RAM in MB
        TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
        TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

        # Calculate swap size based on RAM:
        # - RAM <= 2GB: swap = RAM
        # - RAM <= 8GB: swap = RAM / 2
        # - RAM > 8GB:  swap = 4GB
        if [ "$TOTAL_RAM_GB" -le 2 ]; then
            SWAP_SIZE_MB=$TOTAL_RAM_MB
        elif [ "$TOTAL_RAM_GB" -le 8 ]; then
            SWAP_SIZE_MB=$((TOTAL_RAM_MB / 2))
        else
            SWAP_SIZE_MB=4096
        fi

        SWAP_SIZE_GB=$((SWAP_SIZE_MB / 1024))
        log_info "RAM: ${TOTAL_RAM_MB}MB (~${TOTAL_RAM_GB}GB)"
        log_info "Creating swap file: ${SWAP_SIZE_MB}MB (~${SWAP_SIZE_GB}GB)..."

        SWAP_FILE="/swapfile"

        # Check if swapfile already exists
        if [ -f "$SWAP_FILE" ]; then
            log_warn "Swap file exists but is not active. Activating..."
        else
            # Create swap file
            log_info "Allocating swap space..."
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress

            # Set permissions
            chmod 600 "$SWAP_FILE"

            # Format as swap
            mkswap "$SWAP_FILE"
        fi

        # Enable swap
        swapon "$SWAP_FILE"

        # Add to fstab if not already there
        if ! grep -q "$SWAP_FILE" /etc/fstab; then
            log_info "Adding swap to /etc/fstab..."
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        fi

        # Verify swap is active
        NEW_SWAP=$(free -m | awk '/^Swap:/ {print $2}')
        log_success "Swap configured: ${NEW_SWAP}MB"

        # Set swappiness to a reasonable value (10 = only swap when necessary)
        log_info "Setting swappiness to 10..."
        sysctl vm.swappiness=10

        # Make swappiness persistent
        if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
            echo "vm.swappiness=10" >> /etc/sysctl.conf
        fi
        log_success "Swappiness configured"
    fi
else
    log_info "Skipping swap configuration (CONFIGURE_SWAP=false)"
fi

# ============================================
# Summary
# ============================================

print_complete "System Configuration Complete"

echo -e "${BLUE}System Settings:${NC}"
echo -e "  Timezone:  ${YELLOW}$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone)${NC}"
echo -e "  Hostname:  ${YELLOW}$(hostname)${NC}"
echo -e "  Locale:    ${YELLOW}$(locale | grep LANG= | cut -d= -f2)${NC}"
echo -e "  Swap:      ${YELLOW}$(free -h | awk '/^Swap:/ {print $2}')${NC}"
echo ""

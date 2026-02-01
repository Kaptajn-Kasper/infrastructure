#!/bin/bash
# Create operator user with full sudo access (daily admin account)

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Operator User Setup"

# Set default if not provided
OPERATOR_USER="${OPERATOR_USER:-operator}"

# Validate username
if ! validate_username "$OPERATOR_USER"; then
    log_error "Invalid username: $OPERATOR_USER (must match ^[a-z_][a-z0-9_-]*$)"
    exit 1
fi

log_info "Setting up operator user: $OPERATOR_USER"

# Check if user already exists
if id "$OPERATOR_USER" &>/dev/null; then
    log_success "User $OPERATOR_USER already exists"
else
    log_info "Creating user $OPERATOR_USER..."
    # Check if group with same name exists, use it if so
    if getent group "$OPERATOR_USER" &>/dev/null; then
        useradd -m -s /bin/bash -g "$OPERATOR_USER" "$OPERATOR_USER"
    else
        useradd -m -s /bin/bash "$OPERATOR_USER"
    fi
    log_success "User $OPERATOR_USER created"
fi

# Add user to sudo group
if groups "$OPERATOR_USER" | grep -q sudo; then
    log_success "User $OPERATOR_USER already in sudo group"
else
    log_info "Adding $OPERATOR_USER to sudo group..."
    usermod -aG sudo "$OPERATOR_USER"
    log_success "User added to sudo group"
fi

# Add user to docker group if docker is installed
if command_exists docker; then
    if groups "$OPERATOR_USER" | grep -q docker; then
        log_success "User $OPERATOR_USER already in docker group"
    else
        log_info "Adding $OPERATOR_USER to docker group..."
        usermod -aG docker "$OPERATOR_USER"
        log_success "User added to docker group"
    fi
else
    log_warn "Docker not installed. Skipping docker group assignment"
fi

# Configure passwordless sudo for the operator user (full NOPASSWD: ALL)
SUDOERS_FILE="/etc/sudoers.d/$OPERATOR_USER"
if [ -f "$SUDOERS_FILE" ]; then
    log_success "Sudoers file already exists"
else
    log_info "Configuring passwordless sudo..."
    echo "$OPERATOR_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    # Validate sudoers syntax
    if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
        log_success "Sudoers configuration added and validated"
    else
        log_error "Invalid sudoers syntax. Removing file."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
fi

# Setup SSH directory for the operator user
USER_HOME=$(get_user_home "$OPERATOR_USER")
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

log_info "Setting up SSH directory..."

# Create .ssh directory if it doesn't exist
create_user_dir "$SSH_DIR" "$OPERATOR_USER" 700

# Create authorized_keys file if it doesn't exist
if [ ! -f "$AUTH_KEYS" ]; then
    touch "$AUTH_KEYS"
    log_success "Created authorized_keys file"
else
    log_success "authorized_keys file already exists"
fi

# Set correct ownership and permissions
chown "$OPERATOR_USER:$OPERATOR_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
log_success "Set correct permissions on .ssh directory"

# Copy root's authorized_keys if they exist and operator's is empty
ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"
if [ -f "$ROOT_AUTH_KEYS" ] && [ -s "$ROOT_AUTH_KEYS" ] && [ ! -s "$AUTH_KEYS" ]; then
    log_info "Copying root's authorized_keys to $OPERATOR_USER..."
    cat "$ROOT_AUTH_KEYS" >> "$AUTH_KEYS"
    chown "$OPERATOR_USER:$OPERATOR_USER" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    log_success "Copied authorized_keys from root"
fi

print_complete "Operator User Setup Complete"

echo -e "${BLUE}User Details:${NC}"
echo -e "  Username:   ${YELLOW}$OPERATOR_USER${NC}"
echo -e "  Home:       ${YELLOW}$USER_HOME${NC}"
echo -e "  Groups:     ${YELLOW}$(groups $OPERATOR_USER)${NC}"
echo -e "  Sudo:       ${GREEN}Passwordless (ALL commands)${NC}"
echo ""
echo -e "${BLUE}To connect as this user:${NC}"
if [ -n "$SSH_PORT" ]; then
    echo -e "  ssh -p $SSH_PORT $OPERATOR_USER@[hostname]"
else
    echo -e "  ssh $OPERATOR_USER@[hostname]"
fi
echo ""
echo -e "${YELLOW}Note:${NC} Add your SSH public key to:"
echo -e "  $AUTH_KEYS"
echo ""

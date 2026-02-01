#!/bin/bash
# Create GitHub Actions deployment user with limited sudo access

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "GitHub Actions User Setup"

# Validate GH_ACTIONS_USER
if [ -z "$GH_ACTIONS_USER" ]; then
    log_error "GH_ACTIONS_USER not set in .env file"
    exit 1
fi

if ! validate_username "$GH_ACTIONS_USER"; then
    log_error "Invalid username: $GH_ACTIONS_USER (must match ^[a-z_][a-z0-9_-]*$)"
    exit 1
fi

log_info "Setting up GitHub Actions user: $GH_ACTIONS_USER"

# Check if user already exists
if id "$GH_ACTIONS_USER" &>/dev/null; then
    log_success "User $GH_ACTIONS_USER already exists"
else
    log_info "Creating user $GH_ACTIONS_USER..."
    useradd -m -s /bin/bash "$GH_ACTIONS_USER"
    log_success "User $GH_ACTIONS_USER created"
fi

# Add user to docker group if docker is installed
if command_exists docker; then
    if groups "$GH_ACTIONS_USER" | grep -q docker; then
        log_success "User $GH_ACTIONS_USER already in docker group"
    else
        log_info "Adding $GH_ACTIONS_USER to docker group..."
        usermod -aG docker "$GH_ACTIONS_USER"
        log_success "User added to docker group"
    fi
else
    log_warn "Docker not installed. Skipping docker group assignment"
fi

# Setup SSH directory and keys
USER_HOME=$(get_user_home "$GH_ACTIONS_USER")
SSH_DIR="$USER_HOME/.ssh"
PRIVATE_KEY="$SSH_DIR/gh-actions-deploy-key"
PUBLIC_KEY="$SSH_DIR/gh-actions-deploy-key.pub"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

log_info "Setting up SSH directory..."

# Create .ssh directory
create_user_dir "$SSH_DIR" "$GH_ACTIONS_USER" 700

# Generate SSH key if it doesn't exist
if [ -f "$PRIVATE_KEY" ]; then
    log_success "SSH key already exists"
else
    log_info "Generating SSH key pair..."
    sudo -u "$GH_ACTIONS_USER" ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -N "" -C "${GH_ACTIONS_USER}@github-actions"
    log_success "SSH key pair generated"
fi

# Add public key to authorized_keys if not already there
if [ -f "$PUBLIC_KEY" ]; then
    PUBLIC_KEY_CONTENT=$(cat "$PUBLIC_KEY")

    if [ -f "$AUTHORIZED_KEYS" ] && grep -qF "$PUBLIC_KEY_CONTENT" "$AUTHORIZED_KEYS"; then
        log_success "Public key already in authorized_keys"
    else
        log_info "Adding public key to authorized_keys..."
        cat "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
        log_success "Public key added to authorized_keys"
    fi
fi

# Set correct permissions
log_info "Setting correct permissions..."
chown -R "$GH_ACTIONS_USER:$GH_ACTIONS_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR"/*
if [ -f "$PUBLIC_KEY" ]; then
    chmod 644 "$PUBLIC_KEY"
fi
log_success "Permissions set correctly"

# Configure sudoers for limited passwordless commands (docker and systemctl only)
SUDOERS_FILE="/etc/sudoers.d/$GH_ACTIONS_USER"
if [ -f "$SUDOERS_FILE" ]; then
    log_success "Sudoers file already exists"
else
    log_info "Configuring sudoers for limited passwordless commands..."
    echo "$GH_ACTIONS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/bin/systemctl" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    # Validate sudoers syntax
    if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
        log_success "Sudoers configuration added (docker + systemctl only)"
    else
        log_error "Invalid sudoers syntax. Removing file."
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
fi

print_complete "GitHub Actions User Setup Complete"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}GitHub Secrets Configuration:${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}1. SSH_PRIVATE_KEY:${NC}"
echo -e "   Add the following private key to your GitHub repository secrets:"
echo ""
cat "$PRIVATE_KEY"
echo ""
echo -e "${YELLOW}2. SSH_USER:${NC}"
echo -e "   Value: ${GREEN}$GH_ACTIONS_USER${NC}"
echo ""
echo -e "${YELLOW}3. SSH_HOST:${NC}"
echo -e "   Value: ${GREEN}[Your server IP or hostname]${NC}"
echo ""
if [ -n "$SSH_PORT" ]; then
    echo -e "${YELLOW}4. SSH_PORT:${NC}"
    echo -e "   Value: ${GREEN}$SSH_PORT${NC}"
    echo ""
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Testing the connection:${NC}"
if [ -n "$SSH_PORT" ]; then
    echo -e "  ssh -i $PRIVATE_KEY -p $SSH_PORT $GH_ACTIONS_USER@localhost"
else
    echo -e "  ssh -i $PRIVATE_KEY $GH_ACTIONS_USER@localhost"
fi
echo ""
echo -e "${YELLOW}User details:${NC}"
echo -e "  Home:   $USER_HOME"
echo -e "  Groups: $(groups $GH_ACTIONS_USER)"
echo -e "  Sudo:   docker + systemctl only"
echo ""

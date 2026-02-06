#!/bin/bash
# Setup GitHub CLI and SSH key for the operator user

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "GitHub CLI & SSH Setup"

# Determine which user to set up for
# Priority: OPERATOR_USER > SUDO_USER > root
if [ -n "$OPERATOR_USER" ]; then
    TARGET_USER="$OPERATOR_USER"
elif [ -n "$SUDO_USER" ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="root"
fi

log_info "Setting up GitHub for user: $TARGET_USER"

# Install GitHub CLI if not present
if command_exists gh; then
    log_success "GitHub CLI already installed"
    log_info "Version: $(gh --version | head -1)"
else
    log_info "Installing GitHub CLI..."

    # Debian/Ubuntu only (this repo targets Ubuntu)
    if command_exists apt-get; then
        # Add GitHub CLI repository if not present
        if [ ! -f "/etc/apt/sources.list.d/github-cli.list" ]; then
            log_info "Adding GitHub CLI repository..."

            # Install required packages
            apt-get update -qq
            apt-get install -y -qq curl gpg

            # Add GPG key
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
            chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

            # Add repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list

            log_success "Repository added"
        fi

        # Install gh
        apt-get update -qq
        apt-get install -y gh

        log_success "GitHub CLI installed"
        log_info "Version: $(gh --version | head -1)"
    else
        log_error "Unsupported package manager. Please install GitHub CLI manually."
        log_warn "Visit: https://github.com/cli/cli#installation"
        exit 1
    fi
fi

# Setup SSH key for GitHub
USER_HOME=$(get_user_home "$TARGET_USER")
SSH_DIR="$USER_HOME/.ssh"
GITHUB_KEY="$SSH_DIR/github_ed25519"
GITHUB_KEY_PUB="$GITHUB_KEY.pub"

log_info "Setting up SSH key for GitHub..."

# Create .ssh directory if it doesn't exist
create_user_dir "$SSH_DIR" "$TARGET_USER" 700

# Generate or copy SSH key for GitHub if it doesn't exist
ROOT_KEY_COPIED=false
ROOT_KEY=""
if [ -f "$GITHUB_KEY" ]; then
    log_success "GitHub SSH key already exists"
else
    # If target user is not root, try to copy root's existing SSH key
    # This allows registering a single key with GitHub for both users
    if [ "$TARGET_USER" != "root" ]; then
        ROOT_SSH_DIR="/root/.ssh"
        ROOT_KEY=""

        # Check for existing root SSH keys (in order of preference)
        for candidate in "$ROOT_SSH_DIR/github_ed25519" "$ROOT_SSH_DIR/id_ed25519" "$ROOT_SSH_DIR/id_rsa"; do
            if [ -f "$candidate" ] && [ -f "${candidate}.pub" ]; then
                ROOT_KEY="$candidate"
                break
            fi
        done

        if [ -n "$ROOT_KEY" ]; then
            log_info "Copying root's SSH key ($(basename "$ROOT_KEY")) to $TARGET_USER..."
            cp "$ROOT_KEY" "$GITHUB_KEY"
            cp "${ROOT_KEY}.pub" "$GITHUB_KEY_PUB"
            ROOT_KEY_COPIED=true
            log_success "SSH key copied from root user (single key for both users)"
        fi
    fi

    # Fall back to generating a new key if no root key was copied
    if [ "$ROOT_KEY_COPIED" = false ]; then
        log_info "Generating SSH key for GitHub..."
        sudo -u "$TARGET_USER" ssh-keygen -t ed25519 -f "$GITHUB_KEY" -N "" -C "${TARGET_USER}@$(hostname)-github"
        log_success "SSH key generated"
    fi
fi

# Ensure correct permissions
chown "$TARGET_USER:$TARGET_USER" "$GITHUB_KEY" "$GITHUB_KEY_PUB"
chmod 600 "$GITHUB_KEY"
chmod 644 "$GITHUB_KEY_PUB"

# Configure SSH to use this key for GitHub
SSH_CONFIG="$SSH_DIR/config"
if [ -f "$SSH_CONFIG" ] && grep -q "Host github.com" "$SSH_CONFIG"; then
    log_success "SSH config for GitHub already exists"
else
    log_info "Configuring SSH for GitHub..."

    # Add GitHub SSH configuration
    cat >> "$SSH_CONFIG" << EOF

# GitHub configuration
Host github.com
    HostName github.com
    User git
    IdentityFile $GITHUB_KEY
    IdentitiesOnly yes
EOF

    chown "$TARGET_USER:$TARGET_USER" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
    log_success "SSH config for GitHub added"
fi

# If key was copied from root, also ensure root has a GitHub SSH config
# pointing to its own copy of the key so both users can connect
if [ "$ROOT_KEY_COPIED" = true ] && [ -n "$ROOT_KEY" ]; then
    ROOT_SSH_CONFIG="/root/.ssh/config"
    if [ -f "$ROOT_SSH_CONFIG" ] && grep -q "Host github.com" "$ROOT_SSH_CONFIG"; then
        log_success "Root SSH config for GitHub already exists"
    else
        log_info "Configuring root SSH config for GitHub..."
        cat >> "$ROOT_SSH_CONFIG" << EOF

# GitHub configuration
Host github.com
    HostName github.com
    User git
    IdentityFile $ROOT_KEY
    IdentitiesOnly yes
EOF
        chmod 600 "$ROOT_SSH_CONFIG"
        log_success "Root SSH config for GitHub added"
    fi
fi

print_complete "GitHub CLI Setup Complete"

echo -e "${BLUE}GitHub CLI:${NC}"
echo -e "  Version:    $(gh --version | head -1)"
echo -e "  Location:   $(which gh)"
echo ""
echo -e "${BLUE}SSH Key for GitHub:${NC}"
echo -e "  User:       ${YELLOW}$TARGET_USER${NC}"
echo -e "  Private:    ${YELLOW}$GITHUB_KEY${NC}"
echo -e "  Public:     ${YELLOW}$GITHUB_KEY_PUB${NC}"
if [ "$ROOT_KEY_COPIED" = true ]; then
    echo -e "  Source:     ${GREEN}Copied from root user (shared key)${NC}"
fi
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$ROOT_KEY_COPIED" = true ]; then
    echo -e "${GREEN}Key was copied from root — if already registered with GitHub, no action needed.${NC}"
else
    echo -e "${YELLOW}Add this public key to your GitHub account:${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
cat "$GITHUB_KEY_PUB"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [ "$ROOT_KEY_COPIED" != true ]; then
    echo -e "${YELLOW}Steps to add the key to GitHub:${NC}"
    echo -e "  1. Go to: ${GREEN}https://github.com/settings/ssh/new${NC}"
    echo -e "  2. Title: ${GREEN}$(hostname) - $TARGET_USER${NC}"
    echo -e "  3. Paste the public key above"
    echo -e "  4. Click 'Add SSH key'"
    echo ""
fi
echo -e "${YELLOW}Or use gh CLI to authenticate:${NC}"
echo -e "  sudo -u $TARGET_USER gh auth login"
echo ""
echo -e "${YELLOW}Test the connection:${NC}"
echo -e "  sudo -u $TARGET_USER ssh -T git@github.com"
echo ""

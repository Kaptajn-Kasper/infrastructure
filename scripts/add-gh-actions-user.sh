#!/bin/bash

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory and navigate to parent (infrastructure root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    echo -e "${YELLOW}Please create a .env file with GH_ACTIONS_USER variable in the infrastructure root directory${NC}"
    exit 1
fi

source "$ENV_FILE"

# Check if GH_ACTIONS_USER is set
if [ -z "$GH_ACTIONS_USER" ]; then
    echo -e "${RED}Error: GH_ACTIONS_USER not set in .env file${NC}"
    exit 1
fi

echo -e "${GREEN}Starting GitHub Actions user setup...${NC}"
echo -e "Username: ${YELLOW}$GH_ACTIONS_USER${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Check if user already exists
if id "$GH_ACTIONS_USER" &>/dev/null; then
    echo -e "${GREEN}✓ User $GH_ACTIONS_USER already exists${NC}"
    USER_EXISTS=true
else
    echo -e "${YELLOW}Creating user $GH_ACTIONS_USER...${NC}"
    useradd -m -s /bin/bash "$GH_ACTIONS_USER"
    echo -e "${GREEN}✓ User $GH_ACTIONS_USER created${NC}"
    USER_EXISTS=false
fi

# Add user to docker group if docker is installed
if command -v docker &> /dev/null; then
    if groups "$GH_ACTIONS_USER" | grep -q docker; then
        echo -e "${GREEN}✓ User $GH_ACTIONS_USER already in docker group${NC}"
    else
        echo -e "${YELLOW}Adding $GH_ACTIONS_USER to docker group...${NC}"
        usermod -aG docker "$GH_ACTIONS_USER"
        echo -e "${GREEN}✓ User added to docker group${NC}"
    fi
else
    echo -e "${YELLOW}Docker not installed. Skipping docker group assignment${NC}"
fi

# Setup SSH directory and keys
USER_HOME=$(eval echo ~$GH_ACTIONS_USER)
SSH_DIR="$USER_HOME/.ssh"
PRIVATE_KEY="$SSH_DIR/gh-actions-deploy-key"
PUBLIC_KEY="$SSH_DIR/gh-actions-deploy-key.pub"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

echo -e "${YELLOW}Setting up SSH directory...${NC}"

# Create .ssh directory if it doesn't exist
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    echo -e "${GREEN}✓ Created .ssh directory${NC}"
else
    echo -e "${GREEN}✓ .ssh directory already exists${NC}"
fi

# Always ensure correct ownership and permissions
chown "$GH_ACTIONS_USER:$GH_ACTIONS_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
echo -e "${GREEN}✓ Set correct permissions on .ssh directory${NC}"

# Generate SSH key if it doesn't exist
if [ -f "$PRIVATE_KEY" ]; then
    echo -e "${GREEN}✓ SSH key already exists${NC}"
    KEY_EXISTS=true
else
    echo -e "${YELLOW}Generating SSH key pair...${NC}"
    sudo -u "$GH_ACTIONS_USER" ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -N "" -C "${GH_ACTIONS_USER}@github-actions"
    echo -e "${GREEN}✓ SSH key pair generated${NC}"
    KEY_EXISTS=false
fi

# Add public key to authorized_keys if not already there
if [ -f "$PUBLIC_KEY" ]; then
    PUBLIC_KEY_CONTENT=$(cat "$PUBLIC_KEY")
    
    if [ -f "$AUTHORIZED_KEYS" ] && grep -qF "$PUBLIC_KEY_CONTENT" "$AUTHORIZED_KEYS"; then
        echo -e "${GREEN}✓ Public key already in authorized_keys${NC}"
    else
        echo -e "${YELLOW}Adding public key to authorized_keys...${NC}"
        cat "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
        echo -e "${GREEN}✓ Public key added to authorized_keys${NC}"
    fi
fi

# Set correct permissions
echo -e "${YELLOW}Setting correct permissions...${NC}"
chown -R "$GH_ACTIONS_USER:$GH_ACTIONS_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR"/*
if [ -f "$PUBLIC_KEY" ]; then
    chmod 644 "$PUBLIC_KEY"
fi
echo -e "${GREEN}✓ Permissions set correctly${NC}"

# Configure sudoers for passwordless docker commands (optional but useful)
SUDOERS_FILE="/etc/sudoers.d/$GH_ACTIONS_USER"
if [ -f "$SUDOERS_FILE" ]; then
    echo -e "${GREEN}✓ Sudoers file already exists${NC}"
else
    echo -e "${YELLOW}Configuring sudoers for passwordless commands...${NC}"
    echo "$GH_ACTIONS_USER ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/bin/systemctl" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    echo -e "${GREEN}✓ Sudoers configuration added${NC}"
fi

echo ""
echo -e "${GREEN}=== GitHub Actions User Setup Complete ===${NC}"
echo ""
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
if [ ! -z "$SSH_PORT" ]; then
    echo -e "${YELLOW}4. SSH_PORT:${NC}"
    echo -e "   Value: ${GREEN}$SSH_PORT${NC}"
    echo ""
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Testing the connection:${NC}"
if [ ! -z "$SSH_PORT" ]; then
    echo -e "  ssh -i $PRIVATE_KEY -p $SSH_PORT $GH_ACTIONS_USER@localhost"
else
    echo -e "  ssh -i $PRIVATE_KEY $GH_ACTIONS_USER@localhost"
fi
echo ""
echo -e "${YELLOW}User details:${NC}"
echo -e "  Home: $USER_HOME"
echo -e "  Groups: $(groups $GH_ACTIONS_USER)"
echo ""

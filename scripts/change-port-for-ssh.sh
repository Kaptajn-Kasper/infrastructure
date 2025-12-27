#!/bin/bash

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory and navigate to parent (infrastructure root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    echo -e "${YELLOW}Please create a .env file with SSH_PORT variable in the infrastructure root directory${NC}"
    exit 1
fi

source "$ENV_FILE"

# Check if SSH_PORT is set
if [ -z "$SSH_PORT" ]; then
    echo -e "${RED}Error: SSH_PORT not set${NC}"
    exit 1
fi

# Validate SSH_PORT is a number
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: SSH_PORT must be a number${NC}"
    exit 1
fi

# Check if port is in valid range
if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo -e "${RED}Error: SSH_PORT must be between 1 and 65535${NC}"
    exit 1
fi

echo -e "${GREEN}Starting SSH port configuration...${NC}"
echo -e "New SSH port: ${YELLOW}$SSH_PORT${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Check if SSH is already configured with the desired port
SSHD_CONFIG="/etc/ssh/sshd_config"
CURRENT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" | awk '{print $2}')

if [ "$CURRENT_PORT" = "$SSH_PORT" ]; then
    echo -e "${GREEN}✓ SSH is already configured to use port $SSH_PORT${NC}"
    
    # Verify SSH is actually listening on the port
    if ss -tlnp | grep -q ":$SSH_PORT"; then
        echo -e "${GREEN}✓ SSH is listening on port $SSH_PORT${NC}"
        echo -e "${GREEN}No changes needed - SSH configuration is already correct${NC}"
        exit 0
    else
        echo -e "${YELLOW}Port is configured but SSH is not listening. Proceeding with restart...${NC}"
    fi
fi

# Backup original sshd_config
BACKUP_FILE="${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

echo -e "${YELLOW}Creating backup of sshd_config...${NC}"
cp "$SSHD_CONFIG" "$BACKUP_FILE"
echo -e "${GREEN}Backup created: $BACKUP_FILE${NC}"

# Update SSH port in sshd_config
echo -e "${YELLOW}Updating SSH port configuration...${NC}"

# Remove any existing Port lines (commented or not) and add new one
sed -i '/^#\?Port /d' "$SSHD_CONFIG"
echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

# Validate sshd configuration
echo -e "${YELLOW}Validating SSH configuration...${NC}"
if sshd -t; then
    echo -e "${GREEN}SSH configuration is valid${NC}"
else
    echo -e "${RED}Error: SSH configuration is invalid. Restoring backup...${NC}"
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    exit 1
fi

# Update UFW firewall rules if UFW is installed
if command -v ufw &> /dev/null; then
    echo -e "${YELLOW}Configuring UFW firewall rules...${NC}"
    
    # Check if UFW is enabled
    if ufw status | grep -q "Status: active"; then
        UFW_ACTIVE=true
        echo -e "${GREEN}UFW is active${NC}"
    else
        UFW_ACTIVE=false
        echo -e "${YELLOW}UFW is currently inactive${NC}"
    fi
    
    # Allow new SSH port
    ufw allow "$SSH_PORT/tcp" comment "SSH"
    echo -e "${GREEN}Added UFW rule for port $SSH_PORT${NC}"
    
    # Provide guidance based on UFW status
    if [ "$UFW_ACTIVE" = true ]; then
        # Check if port 22 rule exists
        if ufw status numbered | grep -q "22/tcp"; then
            echo -e "${YELLOW}Note: Port 22 is still open. After verifying the new port works, remove it with:${NC}"
            echo -e "${YELLOW}  sudo ufw delete allow 22/tcp${NC}"
        fi
    else
        echo -e "${YELLOW}To activate the firewall and apply these rules:${NC}"
        echo -e "${YELLOW}  sudo ufw enable${NC}"
        echo -e "${YELLOW}Note: Enable UFW after verifying SSH on port $SSH_PORT works to avoid lockout${NC}"
    fi
else
    echo -e "${YELLOW}UFW not installed. Please manually configure your firewall to allow port $SSH_PORT${NC}"
fi

# Restart SSH service
echo -e "${YELLOW}Restarting SSH service...${NC}"

# Detect the correct SSH service name
SSH_SERVICE=""
if systemctl is-active --quiet ssh 2>/dev/null || systemctl status ssh &>/dev/null; then
    SSH_SERVICE="ssh"
elif systemctl is-active --quiet sshd 2>/dev/null || systemctl status sshd &>/dev/null; then
    SSH_SERVICE="sshd"
else
    echo -e "${RED}Error: Could not find SSH service (tried ssh and sshd)${NC}"
    exit 1
fi

# Check if SSH is using socket activation
if systemctl is-active --quiet "${SSH_SERVICE}.socket" 2>/dev/null; then
    echo -e "${YELLOW}Detected socket activation. Disabling socket and enabling service...${NC}"
    
    # Stop and disable the socket
    systemctl stop "${SSH_SERVICE}.socket"
    systemctl disable "${SSH_SERVICE}.socket"
    
    # Enable and start the service directly
    systemctl enable "$SSH_SERVICE"
    systemctl restart "$SSH_SERVICE"
    
    echo -e "${GREEN}SSH service ($SSH_SERVICE) now running without socket activation${NC}"
else
    # Standard service restart
    if systemctl restart "$SSH_SERVICE"; then
        echo -e "${GREEN}SSH service ($SSH_SERVICE) restarted successfully${NC}"
    else
        echo -e "${RED}Error: Failed to restart SSH service${NC}"
        exit 1
    fi
fi

# Verify SSH is listening on new port
sleep 2
if ss -tlnp | grep -q ":$SSH_PORT"; then
    echo -e "${GREEN}✓ SSH is now listening on port $SSH_PORT${NC}"
else
    echo -e "${RED}Warning: Could not verify SSH is listening on port $SSH_PORT${NC}"
fi

echo ""
echo -e "${GREEN}=== SSH Setup Complete ===${NC}"
echo -e "${YELLOW}IMPORTANT:${NC}"
echo -e "1. Do NOT close this terminal session yet"
echo -e "2. Open a NEW terminal and test the connection:"
echo -e "   ${YELLOW}ssh -p $SSH_PORT user@hostname${NC}"
echo -e "3. Once verified, you can close port 22:"
echo -e "   ${YELLOW}sudo ufw delete allow 22/tcp${NC}"
echo -e "4. Update your SSH config (~/.ssh/config) to use port $SSH_PORT by default"
echo ""

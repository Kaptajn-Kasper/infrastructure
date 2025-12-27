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
    echo -e "${YELLOW}Please create a .env file in the infrastructure root directory${NC}"
    exit 1
fi

source "$ENV_FILE"

echo -e "${GREEN}Starting firewall configuration...${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Check if UFW is installed
if ! command -v ufw &> /dev/null; then
    echo -e "${YELLOW}UFW not installed. Installing...${NC}"
    apt-get update
    apt-get install -y ufw
    echo -e "${GREEN}✓ UFW installed${NC}"
else
    echo -e "${GREEN}✓ UFW is already installed${NC}"
fi

# Check if UFW is enabled
UFW_STATUS=$(ufw status | grep -w "Status:" | awk '{print $2}')

if [ "$UFW_STATUS" = "active" ]; then
    echo -e "${GREEN}✓ UFW is already active${NC}"
    UFW_WAS_ACTIVE=true
else
    echo -e "${YELLOW}UFW is currently inactive${NC}"
    UFW_WAS_ACTIVE=false
fi

echo -e "${YELLOW}Configuring firewall rules...${NC}"

# Set default policies
echo -e "${YELLOW}Setting default policies...${NC}"
ufw --force default deny incoming
ufw --force default allow outgoing
echo -e "${GREEN}✓ Default policies set (deny incoming, allow outgoing)${NC}"

# Function to add rule if it doesn't exist
add_ufw_rule() {
    local port=$1
    local protocol=$2
    local comment=$3
    
    if ufw status | grep -q "${port}/${protocol}"; then
        echo -e "${GREEN}✓ Port $port/$protocol already allowed${NC}"
    else
        echo -e "${YELLOW}Allowing port $port/$protocol...${NC}"
        ufw allow "$port/$protocol" comment "$comment"
        echo -e "${GREEN}✓ Port $port/$protocol allowed${NC}"
    fi
}

# Allow SSH port (from .env)
if [ ! -z "$SSH_PORT" ]; then
    add_ufw_rule "$SSH_PORT" "tcp" "SSH"
else
    add_ufw_rule "22" "tcp" "SSH"
fi

# Allow HTTP (port 80) for web traffic and Let's Encrypt
add_ufw_rule "80" "tcp" "HTTP"

# Allow HTTPS (port 443) for secure web traffic
add_ufw_rule "443" "tcp" "HTTPS"

# Enable UFW if it wasn't already active
if [ "$UFW_WAS_ACTIVE" = false ]; then
    echo -e "${YELLOW}Enabling UFW...${NC}"
    ufw --force enable
    echo -e "${GREEN}✓ UFW enabled${NC}"
else
    echo -e "${YELLOW}Reloading UFW to apply changes...${NC}"
    ufw reload
    echo -e "${GREEN}✓ UFW reloaded${NC}"
fi

echo ""
echo -e "${GREEN}=== Firewall Configuration Complete ===${NC}"
echo ""
echo -e "${YELLOW}Current firewall rules:${NC}"
ufw status numbered
echo ""
echo -e "${GREEN}The following ports are now open:${NC}"
echo -e "  • SSH: ${YELLOW}${SSH_PORT:-22}${NC}"
echo -e "  • HTTP: ${YELLOW}80${NC} (for Let's Encrypt and web traffic)"
echo -e "  • HTTPS: ${YELLOW}443${NC} (for secure web traffic)"
echo ""

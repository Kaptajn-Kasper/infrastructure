#!/bin/bash
# Cloud-init compatible bootstrap script
# Can be pasted into VPS provider's user-data field
#
# Usage:
# 1. Copy this script content
# 2. Paste into your VPS provider's "User Data" or "Cloud-Init" field
# 3. Customize the GITHUB_REPO variable below
# 4. Create the VPS - setup will run automatically on first boot
#
# Alternatively, run directly on a fresh server:
# curl -fsSL https://raw.githubusercontent.com/YOUR_USER/infrastructure/main/bootstrap.sh | sudo bash

set -e

# ============================================
# CONFIGURATION - Customize these values
# ============================================

# Your infrastructure repository (SSH or HTTPS)
GITHUB_REPO="${GITHUB_REPO:-https://github.com/YOUR_USER/infrastructure.git}"

# Branch to checkout (default: main)
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# Temporary directory for clone
TEMP_DIR="/tmp/infrastructure-bootstrap"

# ============================================
# Optional: Override .env values via environment
# ============================================
# Set these as environment variables in cloud-init to customize
# Example in cloud-init:
#   #cloud-config
#   runcmd:
#     - export SSH_PORT=2222
#     - export OPERATOR_USER=admin
#     - curl -fsSL https://raw.githubusercontent.com/.../bootstrap.sh | bash
#
# SSH_PORT=22022
# OPERATOR_USER=operator
# GH_ACTIONS_USER=gh-actions
# INSTALL_DOCKER=true
# INSTALL_CADDY=true
# SERVER_HOSTNAME=myserver

# ============================================
# Bootstrap Script
# ============================================

echo "============================================"
echo "Infrastructure Bootstrap"
echo "============================================"
echo ""

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Update package list
echo "Updating package list..."
apt-get update -qq

# Install git if not present
if ! command -v git &>/dev/null; then
    echo "Installing git..."
    apt-get install -y -qq git
fi

# Clean up any previous bootstrap attempt
rm -rf "$TEMP_DIR"

# Clone the infrastructure repository
echo "Cloning infrastructure repository..."
echo "  Repo: $GITHUB_REPO"
echo "  Branch: $GITHUB_BRANCH"

git clone --depth 1 --branch "$GITHUB_BRANCH" "$GITHUB_REPO" "$TEMP_DIR"

cd "$TEMP_DIR"

# Copy .env.template to .env
if [ ! -f ".env" ]; then
    echo "Creating .env from template..."
    cp .env.template .env
fi

# Override .env values from environment variables (if set)
override_env() {
    local var_name=$1
    local var_value="${!var_name}"

    if [ -n "$var_value" ]; then
        echo "  Overriding $var_name=$var_value"
        if grep -q "^${var_name}=" .env; then
            sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" .env
        else
            echo "${var_name}=${var_value}" >> .env
        fi
    fi
}

echo "Applying environment overrides..."
override_env "SSH_PORT"
override_env "OPERATOR_USER"
override_env "GH_ACTIONS_USER"
override_env "INSTALL_DOCKER"
override_env "INSTALL_CADDY"
override_env "INSTALL_UNATTENDED_UPGRADES"
override_env "CREATE_APP_DIRECTORY"
override_env "CONFIGURE_SWAP"
override_env "CONFIGURE_TIMEZONE"
override_env "SERVER_HOSTNAME"
override_env "AUTO_REBOOT"
override_env "AUTO_REBOOT_TIME"

# Make setup script executable
chmod +x setup.sh

# Run the setup
echo ""
echo "Running infrastructure setup..."
echo "============================================"
./setup.sh

# Cleanup
echo ""
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

echo ""
echo "============================================"
echo "Bootstrap Complete!"
echo "============================================"
echo ""
echo "The server has been configured. You may want to:"
echo "  1. Add your SSH public key to the operator user"
echo "  2. Add the GitHub SSH key to your GitHub account"
echo "  3. Configure your applications in /opt/apps"
echo ""

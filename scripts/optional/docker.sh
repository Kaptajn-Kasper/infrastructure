#!/bin/bash
# Install Docker Engine and Docker Compose plugin

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Docker Installation"

# Check if Docker is already installed
if command_exists docker; then
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
    log_success "Docker is already installed (version $DOCKER_VERSION)"

    # Check if Docker Compose plugin is available
    if docker compose version &>/dev/null; then
        COMPOSE_VERSION=$(docker compose version | awk '{print $4}')
        log_success "Docker Compose plugin is available (version $COMPOSE_VERSION)"
    else
        log_warn "Docker Compose plugin not found, will attempt to install"
    fi
else
    log_info "Installing Docker..."

    # Install prerequisites
    log_info "Installing prerequisites..."
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    log_info "Adding Docker GPG key..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up the repository
    log_info "Adding Docker repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    log_info "Installing Docker Engine..."
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    log_success "Docker installed successfully"
fi

# Configure Docker daemon
DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
    log_info "Configuring Docker daemon..."
    mkdir -p /etc/docker

    cat > "$DOCKER_DAEMON_CONFIG" << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

    log_success "Docker daemon configured"
else
    log_success "Docker daemon config already exists"
fi

# Enable and start Docker service
log_info "Enabling Docker service..."
systemctl enable docker
systemctl start docker
log_success "Docker service is running"

# Add operator user to docker group if they exist
if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" &>/dev/null; then
    if groups "$OPERATOR_USER" | grep -q docker; then
        log_success "User $OPERATOR_USER already in docker group"
    else
        log_info "Adding $OPERATOR_USER to docker group..."
        usermod -aG docker "$OPERATOR_USER"
        log_success "User $OPERATOR_USER added to docker group"
    fi
fi

# Add gh-actions user to docker group if they exist
if [ -n "$GH_ACTIONS_USER" ] && id "$GH_ACTIONS_USER" &>/dev/null; then
    if groups "$GH_ACTIONS_USER" | grep -q docker; then
        log_success "User $GH_ACTIONS_USER already in docker group"
    else
        log_info "Adding $GH_ACTIONS_USER to docker group..."
        usermod -aG docker "$GH_ACTIONS_USER"
        log_success "User $GH_ACTIONS_USER added to docker group"
    fi
fi

# Verify installation
log_info "Verifying Docker installation..."

DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
COMPOSE_VERSION=$(docker compose version 2>/dev/null | awk '{print $4}' || echo "not installed")

print_complete "Docker Installation Complete"

echo -e "${BLUE}Docker:${NC}"
echo -e "  Version:  ${YELLOW}$DOCKER_VERSION${NC}"
echo -e "  Compose:  ${YELLOW}$COMPOSE_VERSION${NC}"
echo -e "  Status:   ${GREEN}$(systemctl is-active docker)${NC}"
echo ""
echo -e "${YELLOW}Test with:${NC}"
echo -e "  docker run hello-world"
echo ""

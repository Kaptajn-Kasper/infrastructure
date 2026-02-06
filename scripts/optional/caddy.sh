#!/bin/bash
# Install Caddy reverse proxy as a Docker container with automatic HTTPS

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Caddy Installation (Docker)"

# --- Preflight: Docker must be installed ---

if ! command_exists docker; then
    log_error "Docker is not installed. Run the Docker setup script first."
    exit 1
fi

if ! docker info &>/dev/null; then
    log_error "Cannot connect to Docker daemon."
    exit 1
fi

# --- Ensure caddy-network exists ---
# (caddy.sh runs before app-directory.sh in setup.sh, so create it here if needed)

if ! docker network ls --format '{{.Name}}' | grep -q '^caddy-network$'; then
    docker network create caddy-network
    log_success "Created Docker network: caddy-network"
else
    log_success "Docker network caddy-network already exists"
fi

# --- Caddy directory layout ---

CADDY_DIR="/opt/apps/caddy"
CADDY_CONF_DIR="$CADDY_DIR/conf.d"
CADDYFILE="$CADDY_DIR/Caddyfile"
OPERATOR="${OPERATOR_USER:-operator}"

mkdir -p "$CADDY_DIR"/{conf.d,data,config}

# --- Migrate from systemd Caddy if present ---

if systemctl is-active --quiet caddy 2>/dev/null; then
    log_info "Detected running systemd Caddy — migrating..."

    # Stop the systemd service
    systemctl stop caddy
    systemctl disable caddy 2>/dev/null || true
    log_success "Stopped and disabled systemd Caddy service"

    # Migrate certificates
    SYSTEMD_CADDY_DATA="/var/lib/caddy/.local/share/caddy"
    if [ -d "$SYSTEMD_CADDY_DATA" ]; then
        cp -a "$SYSTEMD_CADDY_DATA"/. "$CADDY_DIR/data/"
        log_success "Migrated certificates from $SYSTEMD_CADDY_DATA"
    fi

    # Migrate existing snippets
    SYSTEMD_CONF_DIR="/etc/caddy/conf.d"
    if [ -d "$SYSTEMD_CONF_DIR" ] && [ -n "$(ls -A "$SYSTEMD_CONF_DIR" 2>/dev/null)" ]; then
        cp -a "$SYSTEMD_CONF_DIR"/. "$CADDY_CONF_DIR/"
        log_success "Migrated snippets from $SYSTEMD_CONF_DIR"
    fi
fi

# --- Create Caddyfile if it doesn't exist ---

if [ ! -f "$CADDYFILE" ] || [ ! -s "$CADDYFILE" ]; then
    log_info "Creating default Caddyfile..."

    cat > "$CADDYFILE" << 'EOF'
# Caddy Configuration
# ====================
# Documentation: https://caddyserver.com/docs/caddyfile
#
# Apps on caddy-network are reachable by container name:
#   app.example.com {
#       reverse_proxy my-container:3000
#   }

# Import per-app configs from conf.d/
import /etc/caddy/conf.d/*.caddy

# Default: respond with placeholder on bare IP
:80 {
    respond "Caddy is running. Configure your domains in conf.d/"
}
EOF

    log_success "Default Caddyfile created"
else
    log_success "Caddyfile already exists"
fi

# --- Create docker-compose.yml ---

COMPOSE_FILE="$CADDY_DIR/docker-compose.yml"

cat > "$COMPOSE_FILE" << 'EOF'
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./conf.d:/etc/caddy/conf.d:ro
      - ./data:/data
      - ./config:/config
    networks:
      - caddy-network

networks:
  caddy-network:
    external: true
    name: caddy-network
EOF

log_success "Docker Compose file created"

# --- Set ownership ---

chown -R "$OPERATOR:$OPERATOR" "$CADDY_DIR"

# --- Open firewall ports (if UFW is active) ---

if command_exists ufw && ufw status | grep -q "Status: active"; then
    log_info "Configuring firewall for Caddy..."
    add_ufw_rule "80" "tcp" "HTTP (Caddy)"
    add_ufw_rule "443" "tcp" "HTTPS (Caddy)"
fi

# --- Start Caddy container ---

log_info "Starting Caddy container..."
docker compose -f "$COMPOSE_FILE" up -d
log_success "Caddy container is running"

# --- Validate configuration ---

log_info "Validating Caddy configuration..."
if docker exec caddy caddy validate --config /etc/caddy/Caddyfile &>/dev/null; then
    log_success "Caddy configuration is valid"
else
    log_warn "Caddy configuration has issues. Check with: docker exec caddy caddy validate --config /etc/caddy/Caddyfile"
fi

print_complete "Caddy Installation Complete"

echo -e "${BLUE}Caddy (Docker):${NC}"
echo -e "  Container:  ${GREEN}$(docker ps --format '{{.Image}}' -f name=^caddy$)${NC}"
echo -e "  Config:     ${YELLOW}$CADDYFILE${NC}"
echo -e "  Snippets:   ${YELLOW}$CADDY_CONF_DIR/${NC}"
echo -e "  Status:     ${GREEN}$(docker ps --format '{{.Status}}' -f name=^caddy$)${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Add per-app configs to ${GREEN}$CADDY_CONF_DIR/<app>.caddy${NC}"
echo -e "  2. Reload: ${GREEN}docker exec caddy caddy reload --config /etc/caddy/Caddyfile${NC}"
echo ""
echo -e "${YELLOW}Example — ${CADDY_CONF_DIR}/myapp.caddy:${NC}"
echo -e "  myapp.example.com {"
echo -e "      reverse_proxy myapp-container:3000"
echo -e "  }"
echo ""

#!/bin/bash
# Create /opt/apps directory structure for application deployment

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Application Directory Setup"

APPS_DIR="/opt/apps"
OPERATOR="${OPERATOR_USER:-operator}"

# Check if operator user exists
if ! id "$OPERATOR" &>/dev/null; then
    log_warn "Operator user '$OPERATOR' does not exist. Directory will be owned by root."
    OWNER="root"
else
    OWNER="$OPERATOR"
fi

# Create main apps directory
if [ -d "$APPS_DIR" ]; then
    log_success "Directory $APPS_DIR already exists"
else
    log_info "Creating $APPS_DIR..."
    mkdir -p "$APPS_DIR"
    log_success "Created $APPS_DIR"
fi

# Create subdirectories
log_info "Creating subdirectory structure..."

SUBDIRS=(
    "data"      # Persistent data volumes
    "configs"   # Application configurations
    "logs"      # Application logs
    "backups"   # Backup storage
)

for subdir in "${SUBDIRS[@]}"; do
    SUBDIR_PATH="$APPS_DIR/$subdir"
    if [ -d "$SUBDIR_PATH" ]; then
        log_success "$subdir/ already exists"
    else
        mkdir -p "$SUBDIR_PATH"
        log_success "Created $subdir/"
    fi
done

# Set ownership
log_info "Setting ownership to $OWNER..."
chown -R "$OWNER:$OWNER" "$APPS_DIR"
chmod 755 "$APPS_DIR"

# Create example docker-compose.yml template
EXAMPLE_COMPOSE="$APPS_DIR/docker-compose.example.yml"
if [ ! -f "$EXAMPLE_COMPOSE" ]; then
    log_info "Creating example docker-compose.yml..."

    cat > "$EXAMPLE_COMPOSE" << 'EOF'
# Example Docker Compose configuration
# Copy this file and customize for your application
#
# Usage:
#   cp docker-compose.example.yml myapp/docker-compose.yml
#   cd myapp && docker compose up -d

version: "3.8"

services:
  app:
    image: your-app-image:latest
    container_name: myapp
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
    volumes:
      - ./data:/app/data
      - ./configs:/app/config:ro
    networks:
      - caddy-network

  # Optional: Add a database
  # db:
  #   image: postgres:15-alpine
  #   container_name: myapp-db
  #   restart: unless-stopped
  #   environment:
  #     - POSTGRES_DB=myapp
  #     - POSTGRES_USER=myapp
  #     - POSTGRES_PASSWORD=${DB_PASSWORD}
  #   volumes:
  #     - ./data/postgres:/var/lib/postgresql/data
  #   networks:
  #     - caddy-network

networks:
  caddy-network:
    external: true
    name: caddy-network

# Create the network with:
# docker network create caddy-network
#
# Then configure Caddy to reverse proxy:
# myapp.example.com {
#     reverse_proxy app:3000
# }
EOF

    chown "$OWNER:$OWNER" "$EXAMPLE_COMPOSE"
    log_success "Created example docker-compose.yml"
fi

# Create a README for the apps directory
README_FILE="$APPS_DIR/README.md"
if [ ! -f "$README_FILE" ]; then
    log_info "Creating README..."

    cat > "$README_FILE" << 'EOF'
# Applications Directory

This directory is for deploying Docker Compose applications.

## Directory Structure

```
/opt/apps/
├── data/       # Persistent data volumes
├── configs/    # Application configurations
├── logs/       # Application logs
├── backups/    # Backup storage
└── myapp/      # Your applications go here
```

## Deploying a New Application

1. Create a directory for your app:
   ```bash
   mkdir -p /opt/apps/myapp
   cd /opt/apps/myapp
   ```

2. Clone your repository or create docker-compose.yml:
   ```bash
   git clone git@github.com:user/myapp.git .
   # or
   cp /opt/apps/docker-compose.example.yml docker-compose.yml
   ```

3. Start the application:
   ```bash
   docker compose up -d
   ```

4. Configure Caddy reverse proxy:
   Edit `/etc/caddy/Caddyfile`:
   ```
   myapp.example.com {
       reverse_proxy myapp:3000
   }
   ```

5. Reload Caddy:
   ```bash
   sudo systemctl reload caddy
   ```

## Common Commands

```bash
# View running containers
docker ps

# View logs
docker compose logs -f

# Restart application
docker compose restart

# Update and restart
docker compose pull && docker compose up -d

# Stop application
docker compose down
```

## Creating the Caddy Network

For Caddy to communicate with containers, create a shared network:

```bash
docker network create caddy-network
```

Then add this to your docker-compose.yml:

```yaml
networks:
  caddy-network:
    external: true
    name: caddy-network
```
EOF

    chown "$OWNER:$OWNER" "$README_FILE"
    log_success "Created README.md"
fi

# Create caddy network if Docker is installed
if command_exists docker; then
    if docker network ls | grep -q "caddy-network"; then
        log_success "Docker network 'caddy-network' already exists"
    else
        log_info "Creating Docker network 'caddy-network'..."
        docker network create caddy-network
        log_success "Created 'caddy-network' for Caddy reverse proxy"
    fi
fi

print_complete "Application Directory Setup Complete"

echo -e "${BLUE}Directory Structure:${NC}"
echo -e "  ${YELLOW}$APPS_DIR/${NC}"
for subdir in "${SUBDIRS[@]}"; do
    echo -e "    ├── ${subdir}/"
done
echo -e "    ├── docker-compose.example.yml"
echo -e "    └── README.md"
echo ""
echo -e "${BLUE}Ownership:${NC} ${YELLOW}$OWNER${NC}"
echo ""
echo -e "${YELLOW}Deploy an app:${NC}"
echo -e "  cd $APPS_DIR"
echo -e "  git clone git@github.com:user/myapp.git myapp"
echo -e "  cd myapp && docker compose up -d"
echo ""

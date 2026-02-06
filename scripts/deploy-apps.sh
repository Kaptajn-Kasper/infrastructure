#!/bin/bash
# Deploy applications from the apps.conf manifest
#
# Reads apps.conf, clones/pulls each repo into /opt/apps/<dir>,
# runs docker compose up, and configures Caddy reverse proxy snippets.
#
# Usage:
#   deploy-apps                      Deploy all apps
#   deploy-apps --app <name>         Deploy a single app by directory name
#   deploy-apps --pull-only          Update repos without restarting containers
#   deploy-apps --no-caddy           Skip Caddy configuration and reload

set -euo pipefail

# Resolve symlinks so we find the real script location
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Configuration ---

INFRA_ROOT="$(dirname "$SCRIPT_DIR")"
APPS_CONF="$INFRA_ROOT/apps.conf"
APPS_DIR="/opt/apps"
CADDY_CONF_DIR="/opt/apps/caddy/conf.d"
LOG_DIR="$APPS_DIR/logs"
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d_%H%M%S).log"

# --- Parse arguments ---

TARGET_APP=""
PULL_ONLY=false
SKIP_CADDY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            TARGET_APP="$2"
            shift 2
            ;;
        --pull-only)
            PULL_ONLY=true
            shift
            ;;
        --no-caddy)
            SKIP_CADDY=true
            shift
            ;;
        -h|--help)
            echo "Usage: deploy-apps [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --app <name>    Deploy a single app by its directory name"
            echo "  --pull-only     Update repos without restarting containers"
            echo "  --no-caddy      Skip Caddy snippet configuration and reload"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Preflight checks ---

if [ ! -f "$APPS_CONF" ]; then
    log_error "App manifest not found: $APPS_CONF"
    exit 1
fi

if [ ! -d "$APPS_DIR" ]; then
    log_error "Apps directory not found: $APPS_DIR"
    log_error "Run the app-directory setup script first."
    exit 1
fi

if ! command_exists docker; then
    log_error "Docker is not installed."
    exit 1
fi

if ! docker info &>/dev/null; then
    log_error "Cannot connect to Docker. Is your user in the docker group?"
    exit 1
fi

mkdir -p "$LOG_DIR" 2>/dev/null || true

# --- Deploy ---

print_header "App Deployment"

TOTAL=0
SUCCEEDED=0
FAILED=0
WARNINGS=0
CADDY_CHANGED=false

CONFIGS_DIR="$APPS_DIR/configs"

# Seed the config directory with example files from the app repo.
# Finds files matching common "example" patterns and copies them
# into /opt/apps/configs/<app>/ with the example part stripped.
# Only copies files that don't already exist in the config dir.
seed_configs() {
    local app_dir="$1"
    local dir_name="$2"
    local config_dir="$CONFIGS_DIR/$dir_name"
    local seeded=0

    # Find example/template files: .env.example, *.example.*, *.template.*
    while IFS= read -r -d '' example_file; do
        # Get path relative to app dir
        local rel_path="${example_file#$app_dir/}"

        # Strip the example/template part from the filename
        local target_name
        target_name=$(echo "$rel_path" | sed -E 's/\.example\./\./; s/\.template\./\./; s/\.example$//; s/\.template$//')

        local config_dest="$config_dir/$target_name"

        if [ ! -f "$config_dest" ]; then
            mkdir -p "$(dirname "$config_dest")"
            cp "$example_file" "$config_dest"
            seeded=$((seeded + 1))
            log_info "  Seeded $target_name from $rel_path"
        fi
    done < <(find "$app_dir" -maxdepth 3 \
        \( -name "*.example.*" -o -name "*.example" -o -name "*.template.*" -o -name "*.template" \) \
        -not -path "$app_dir/.git/*" \
        -print0 2>/dev/null)

    if [ "$seeded" -gt 0 ]; then
        log_warn "$dir_name: $seeded config file(s) seeded into $config_dir"
        log_warn "  Edit them with your actual values, then re-run deploy-apps"
        WARNINGS=$((WARNINGS + 1))
        return 1
    fi
    return 0
}

# Copy config files from /opt/apps/configs/<app>/ into the app directory,
# preserving relative paths.
inject_configs() {
    local app_dir="$1"
    local dir_name="$2"
    local config_dir="$CONFIGS_DIR/$dir_name"
    local injected=0

    if [ ! -d "$config_dir" ] || [ -z "$(ls -A "$config_dir" 2>/dev/null)" ]; then
        return 0
    fi

    while IFS= read -r -d '' config_file; do
        local rel_path="${config_file#$config_dir/}"
        local dest="$app_dir/$rel_path"
        mkdir -p "$(dirname "$dest")"
        cp "$config_file" "$dest"
        injected=$((injected + 1))
    done < <(find "$config_dir" -type f -print0 2>/dev/null)

    if [ "$injected" -gt 0 ]; then
        log_success "Injected $injected config file(s) from $config_dir"
    fi
}

find_compose_file() {
    local app_dir="$1"
    local candidates=("docker-compose.yml" "compose.yml" "docker-compose.prod.yml")
    for candidate in "${candidates[@]}"; do
        if [ -f "$app_dir/$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

deploy_app() {
    local repo="$1"
    local dir_name="$2"
    local compose_file="${3:-}"
    local app_dir="$APPS_DIR/$dir_name"

    log_step "Deploying $dir_name ($repo)"

    # Clone or pull
    if [ -d "$app_dir/.git" ]; then
        log_info "Pulling latest changes..."
        if git -C "$app_dir" pull --ff-only 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Updated $dir_name"
        else
            log_fail "Failed to pull $dir_name"
            return 1
        fi
    else
        log_info "Cloning $repo..."
        if git clone "git@github.com:$repo.git" "$app_dir" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Cloned $dir_name"
        else
            log_fail "Failed to clone $dir_name"
            return 1
        fi
    fi

    # Config injection: seed example files on first deploy, inject on every deploy
    seed_configs "$app_dir" "$dir_name"
    local seed_status=$?
    inject_configs "$app_dir" "$dir_name"

    # If configs were just seeded (first deploy), stop here — user needs to edit them
    if [ "$seed_status" -ne 0 ]; then
        return 0
    fi

    # Resolve compose file
    local resolved_compose=""
    if [ -n "$compose_file" ]; then
        if [ -f "$app_dir/$compose_file" ]; then
            resolved_compose="$compose_file"
        else
            log_fail "Specified compose file not found: $compose_file"
            return 1
        fi
    else
        resolved_compose=$(find_compose_file "$app_dir") || true
    fi

    # Start containers (unless --pull-only)
    if [ "$PULL_ONLY" = true ]; then
        log_info "Skipping container start (--pull-only)"
    else
        if [ -z "$resolved_compose" ]; then
            log_warn "$dir_name has no compose file — skipping container start"
            WARNINGS=$((WARNINGS + 1))
        else
            log_info "Starting containers ($resolved_compose)..."
            if docker compose -f "$app_dir/$resolved_compose" up -d --build 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Containers started for $dir_name"
            else
                log_fail "Failed to start containers for $dir_name"
                return 1
            fi
        fi
    fi

    # Caddy snippet
    if [ "$SKIP_CADDY" = false ] && [ -f "$app_dir/Caddyfile.snippet" ]; then
        local caddy_dest="$CADDY_CONF_DIR/$dir_name.caddy"
        if ! diff -q "$app_dir/Caddyfile.snippet" "$caddy_dest" &>/dev/null; then
            cp "$app_dir/Caddyfile.snippet" "$caddy_dest"
            log_success "Updated Caddy config for $dir_name"
            CADDY_CHANGED=true
        else
            log_success "Caddy config for $dir_name unchanged"
        fi
    fi

    return 0
}

# Read manifest and deploy
while IFS= read -r line; do
    # Skip comments and blank lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse: repo dir_name [compose_file]
    repo=$(echo "$line" | awk '{print $1}')
    dir_name=$(echo "$line" | awk '{print $2}')
    compose_file=$(echo "$line" | awk '{print $3}')

    if [ -z "$repo" ] || [ -z "$dir_name" ]; then
        log_warn "Skipping malformed line: $line"
        continue
    fi

    # If targeting a specific app, skip others
    if [ -n "$TARGET_APP" ] && [ "$dir_name" != "$TARGET_APP" ]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))

    if deploy_app "$repo" "$dir_name" "$compose_file"; then
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        FAILED=$((FAILED + 1))
    fi

    echo ""
done < "$APPS_CONF"

# Check if targeted app was found
if [ -n "$TARGET_APP" ] && [ "$TOTAL" -eq 0 ]; then
    log_error "App '$TARGET_APP' not found in $APPS_CONF"
    exit 1
fi

# Reload Caddy if any snippets changed
if [ "$CADDY_CHANGED" = true ]; then
    log_step "Reloading Caddy"
    if docker exec caddy caddy validate --config /etc/caddy/Caddyfile &>/dev/null; then
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile
        log_success "Caddy reloaded"
    else
        log_fail "Caddy config validation failed — not reloading"
        log_warn "Run 'docker exec caddy caddy validate --config /etc/caddy/Caddyfile' to see errors"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# --- Summary ---

print_complete "Deployment Complete"

echo -e "${BLUE}Results:${NC}"
echo -e "  Total:     $TOTAL"
echo -e "  ${GREEN}Succeeded: $SUCCEEDED${NC}"
[ "$FAILED" -gt 0 ] && echo -e "  ${RED}Failed:    $FAILED${NC}"
[ "$WARNINGS" -gt 0 ] && echo -e "  ${YELLOW}Warnings:  $WARNINGS${NC}"
echo -e "  Log:       $LOG_FILE"
echo ""

[ "$FAILED" -gt 0 ] && exit 1
exit 0

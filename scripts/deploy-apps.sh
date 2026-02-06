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
#   deploy-apps --app <name> --env dev --branch feature/x
#                                    Deploy a branch to an isolated environment
#   deploy-apps --app <name> --env dev --teardown
#                                    Tear down an environment

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
DEPLOY_ENV=""
DEPLOY_BRANCH=""
TEARDOWN=false

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
        --env)
            DEPLOY_ENV="$2"
            shift 2
            ;;
        --branch)
            DEPLOY_BRANCH="$2"
            shift 2
            ;;
        --teardown)
            TEARDOWN=true
            shift
            ;;
        -h|--help)
            echo "Usage: deploy-apps [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --app <name>        Deploy a single app by its directory name"
            echo "  --pull-only         Update repos without restarting containers"
            echo "  --no-caddy          Skip Caddy snippet configuration and reload"
            echo "  --env <name>        Deploy to a named environment (e.g. dev, staging)"
            echo "  --branch <branch>   Git branch to deploy (default: main)"
            echo "  --teardown          Tear down the specified --env environment"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Validate environment flags ---

if [ "$TEARDOWN" = true ] && [ -z "$DEPLOY_ENV" ]; then
    log_error "--teardown requires --env"
    exit 1
fi

if [ "$DEPLOY_ENV" = "prod" ]; then
    log_error "--env prod is not allowed. Prod is the default (no --env flag)."
    exit 1
fi

if [ -n "$DEPLOY_ENV" ] && ! [[ "$DEPLOY_ENV" =~ ^[a-z][a-z0-9-]*$ ]]; then
    log_error "Invalid environment name '$DEPLOY_ENV'. Must match ^[a-z][a-z0-9-]*$"
    exit 1
fi

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

if [ "$TEARDOWN" = true ]; then
    print_header "App Teardown (env: $DEPLOY_ENV)"
elif [ -n "$DEPLOY_ENV" ]; then
    print_header "App Deployment (env: $DEPLOY_ENV)"
else
    print_header "App Deployment"
fi

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

# Generate a docker compose override file that remaps container names for the
# given environment. Reads the base compose file and replaces -prod suffixes
# (or appends -<env>) on every container_name entry.
generate_compose_override() {
    local app_dir="$1"
    local dir_name="$2"
    local env_name="$3"
    local compose_file="$4"
    local override_file="$app_dir/.compose.env-override.yml"

    log_info "Generating compose override for env '$env_name'..."

    # Start building the override YAML
    local services_block=""
    local current_service=""

    while IFS= read -r line; do
        # Track service names (lines with exactly 2-space indent followed by a key)
        if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]*$ ]]; then
            current_service="${BASH_REMATCH[1]}"
        fi

        # Match lines like: container_name: some-name
        if [[ "$line" =~ container_name:[[:space:]]*(.+)$ ]]; then
            local original_name="${BASH_REMATCH[1]}"

            # Determine the new container name
            local new_name
            if [[ "$original_name" =~ -prod$ ]]; then
                new_name="${original_name%-prod}-${env_name}"
            else
                new_name="${original_name}-${env_name}"
            fi

            services_block+="    ${current_service}:"$'\n'
            services_block+="      container_name: ${new_name}"$'\n'
        fi
    done < "$app_dir/$compose_file"

    cat > "$override_file" <<EOF
# Auto-generated by deploy-apps --env $env_name
services:
$services_block
EOF

    log_success "Created compose override: $override_file"
}

# Tear down an environment: stop containers, remove clone dir and Caddy snippet.
# Preserves the config directory to avoid accidental secret loss.
teardown_app() {
    local dir_name="$1"
    local compose_file="${2:-}"
    local effective_dir="${dir_name}-${DEPLOY_ENV}"
    local app_dir="$APPS_DIR/$effective_dir"

    log_step "Tearing down $effective_dir"

    # Stop and remove containers
    if [ -d "$app_dir" ]; then
        local resolved_compose=""
        if [ -n "$compose_file" ] && [ -f "$app_dir/$compose_file" ]; then
            resolved_compose="$compose_file"
        else
            resolved_compose=$(find_compose_file "$app_dir") || true
        fi

        if [ -n "$resolved_compose" ]; then
            local compose_args=(-f "$app_dir/$resolved_compose")
            if [ -f "$app_dir/.compose.env-override.yml" ]; then
                compose_args+=(-f "$app_dir/.compose.env-override.yml")
            fi
            log_info "Stopping containers..."
            docker compose "${compose_args[@]}" down 2>&1 | tee -a "$LOG_FILE" || true
        fi

        log_info "Removing clone directory: $app_dir"
        rm -rf "$app_dir"
        log_success "Removed $app_dir"
    else
        log_warn "Clone directory not found: $app_dir"
    fi

    # Remove Caddy snippet
    local caddy_file="$CADDY_CONF_DIR/$effective_dir.caddy"
    if [ -f "$caddy_file" ]; then
        rm -f "$caddy_file"
        log_success "Removed Caddy snippet: $caddy_file"
        CADDY_CHANGED=true
    fi

    # Warn about config directory
    local config_dir="$CONFIGS_DIR/$effective_dir"
    if [ -d "$config_dir" ]; then
        log_warn "Config directory preserved: $config_dir"
        log_warn "  Remove manually if no longer needed: rm -rf $config_dir"
    fi

    return 0
}

deploy_app() {
    local repo="$1"
    local dir_name="$2"
    local compose_file="${3:-}"

    # Compute effective directory name (env-suffixed when deploying to a named env)
    local effective_dir="$dir_name"
    if [ -n "$DEPLOY_ENV" ]; then
        effective_dir="${dir_name}-${DEPLOY_ENV}"
    fi

    local app_dir="$APPS_DIR/$effective_dir"

    if [ -n "$DEPLOY_ENV" ]; then
        log_step "Deploying $dir_name to env '$DEPLOY_ENV' ($repo)"
    else
        log_step "Deploying $dir_name ($repo)"
    fi

    # Clone or pull
    if [ -d "$app_dir/.git" ]; then
        log_info "Pulling latest changes..."
        if [ -n "$DEPLOY_BRANCH" ]; then
            if git -C "$app_dir" fetch 2>&1 | tee -a "$LOG_FILE" \
                && git -C "$app_dir" checkout "$DEPLOY_BRANCH" 2>&1 | tee -a "$LOG_FILE" \
                && git -C "$app_dir" pull --ff-only 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Updated $effective_dir (branch: $DEPLOY_BRANCH)"
            else
                log_fail "Failed to pull $effective_dir (branch: $DEPLOY_BRANCH)"
                return 1
            fi
        else
            if git -C "$app_dir" pull --ff-only 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Updated $effective_dir"
            else
                log_fail "Failed to pull $effective_dir"
                return 1
            fi
        fi
    else
        log_info "Cloning $repo..."
        local clone_args=("git@github.com:$repo.git" "$app_dir")
        if [ -n "$DEPLOY_BRANCH" ]; then
            clone_args=(-b "$DEPLOY_BRANCH" "${clone_args[@]}")
        fi
        if git clone "${clone_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Cloned $effective_dir"
        else
            log_fail "Failed to clone $effective_dir"
            return 1
        fi
    fi

    # Config injection: seed example files on first deploy, inject on every deploy
    seed_configs "$app_dir" "$effective_dir"
    local seed_status=$?
    inject_configs "$app_dir" "$effective_dir"

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

    # Generate compose override for named environments
    if [ -n "$DEPLOY_ENV" ] && [ -n "$resolved_compose" ]; then
        generate_compose_override "$app_dir" "$dir_name" "$DEPLOY_ENV" "$resolved_compose"
    fi

    # Start containers (unless --pull-only)
    if [ "$PULL_ONLY" = true ]; then
        log_info "Skipping container start (--pull-only)"
    else
        if [ -z "$resolved_compose" ]; then
            log_warn "$effective_dir has no compose file — skipping container start"
            WARNINGS=$((WARNINGS + 1))
        else
            local compose_args=(-f "$app_dir/$resolved_compose")
            if [ -n "$DEPLOY_ENV" ] && [ -f "$app_dir/.compose.env-override.yml" ]; then
                compose_args+=(-f "$app_dir/.compose.env-override.yml")
            fi
            log_info "Starting containers ($resolved_compose)..."
            if docker compose "${compose_args[@]}" up -d --build 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Containers started for $effective_dir"
            else
                log_fail "Failed to start containers for $effective_dir"
                return 1
            fi
        fi
    fi

    # Caddy snippet
    if [ "$SKIP_CADDY" = false ]; then
        local snippet_name="Caddyfile.snippet"
        if [ -n "$DEPLOY_ENV" ]; then
            snippet_name="Caddyfile.snippet.${DEPLOY_ENV}"
        fi

        if [ -f "$app_dir/$snippet_name" ]; then
            local caddy_dest="$CADDY_CONF_DIR/$effective_dir.caddy"
            if ! diff -q "$app_dir/$snippet_name" "$caddy_dest" &>/dev/null; then
                cp "$app_dir/$snippet_name" "$caddy_dest"
                log_success "Updated Caddy config for $effective_dir"
                CADDY_CHANGED=true
            else
                log_success "Caddy config for $effective_dir unchanged"
            fi
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

    if [ "$TEARDOWN" = true ]; then
        if teardown_app "$dir_name" "$compose_file"; then
            SUCCEEDED=$((SUCCEEDED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    else
        if deploy_app "$repo" "$dir_name" "$compose_file"; then
            SUCCEEDED=$((SUCCEEDED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
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

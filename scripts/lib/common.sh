#!/bin/bash
# Shared functions library for infrastructure setup scripts
# Source this file at the beginning of each script

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export NC='\033[0m' # No Color

# Logging configuration
LOG_FILE="${LOG_FILE:-/var/log/infrastructure-setup.log}"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Core logging function
log() {
    local level=$1
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"

    # Write to log file
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true

    # Output to console with colors
    case $level in
        INFO)  echo -e "${GREEN}$*${NC}" ;;
        WARN)  echo -e "${YELLOW}$*${NC}" ;;
        ERROR) echo -e "${RED}$*${NC}" ;;
        STEP)  echo -e "${BLUE}$*${NC}" ;;
        *)     echo -e "$*" ;;
    esac
}

# Convenience logging functions
log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_step()  {
    echo -e "${BLUE}━━━ $* ━━━${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STEP] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# Check mark and cross output (only prints once to console, logs to file)
log_success() {
    echo -e "${GREEN}✓ $*${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] ✓ $*" >> "$LOG_FILE" 2>/dev/null || true
}
log_fail() {
    echo -e "${RED}✗ $*${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] ✗ $*" >> "$LOG_FILE" 2>/dev/null || true
}

# Backup a file with timestamp
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log_info "Backed up $file to $backup"
        echo "$backup"  # Return the backup path
    fi
}

# Check if running as root
require_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Idempotent package installation
ensure_package() {
    local pkg=$1
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        log_info "$pkg already installed"
        return 0
    else
        log_info "Installing $pkg..."
        apt-get install -y -qq "$pkg"
        return $?
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Get the infrastructure root directory
get_infra_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

    # Navigate up to find the infrastructure root (contains .env.template)
    local dir="$script_dir"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.env.template" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done

    # Fallback: assume scripts are in scripts/core or scripts/optional
    echo "$(dirname "$(dirname "$script_dir")")"
}

# Load environment file
load_env() {
    local infra_root
    infra_root="$(get_infra_root)"
    local env_file="$infra_root/.env"

    if [ ! -f "$env_file" ]; then
        log_error ".env file not found at $env_file"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$env_file"
    log_info "Loaded configuration from $env_file"
}

# Validate a username format
validate_username() {
    local username=$1
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate a port number
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# Validate a boolean value
validate_boolean() {
    local value=$1
    if [ "$value" = "true" ] || [ "$value" = "false" ]; then
        return 0
    else
        return 1
    fi
}

# Check if a service is active
service_is_active() {
    local service=$1
    systemctl is-active --quiet "$service" 2>/dev/null
}

# Enable and start a service
enable_service() {
    local service=$1
    systemctl enable "$service" 2>/dev/null
    systemctl start "$service" 2>/dev/null
}

# Restart a service
restart_service() {
    local service=$1
    systemctl restart "$service" 2>/dev/null
}

# Add a UFW rule if it doesn't exist
add_ufw_rule() {
    local port=$1
    local protocol=${2:-tcp}
    local comment=${3:-""}

    if ufw status | grep -q "${port}/${protocol}"; then
        log_info "UFW rule for $port/$protocol already exists"
    else
        if [ -n "$comment" ]; then
            ufw allow "$port/$protocol" comment "$comment"
        else
            ufw allow "$port/$protocol"
        fi
        log_success "Added UFW rule for $port/$protocol"
    fi
}

# Get user's home directory
get_user_home() {
    local username=$1
    eval echo "~$username"
}

# Create directory with proper ownership
create_user_dir() {
    local dir=$1
    local owner=$2
    local perms=${3:-755}

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_success "Created directory $dir"
    fi

    chown "$owner:$owner" "$dir"
    chmod "$perms" "$dir"
}

# Print a section header
print_header() {
    local title=$1
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    printf "${BLUE}║${NC} %-58s ${BLUE}║${NC}\n" "$title"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Print a completion message
print_complete() {
    local title=$1
    echo ""
    echo -e "${GREEN}=== $title ===${NC}"
    echo ""
}

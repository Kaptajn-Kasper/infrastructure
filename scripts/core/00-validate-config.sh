#!/bin/bash
# Validate configuration before running any other setup scripts

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
load_env

print_header "Configuration Validation"

ERRORS=0

# Helper function to report errors
validation_error() {
    log_error "$1"
    ((ERRORS++))
}

validation_success() {
    log_success "$1"
}

# --- Validate SSH_PORT ---
log_info "Validating SSH_PORT..."
if [ -z "$SSH_PORT" ]; then
    validation_error "SSH_PORT is not set"
elif ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    validation_error "SSH_PORT must be a number (got: $SSH_PORT)"
elif [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    validation_error "SSH_PORT must be between 1024 and 65535 (got: $SSH_PORT)"
else
    validation_success "SSH_PORT=$SSH_PORT"
fi

# --- Validate OPERATOR_USER ---
log_info "Validating OPERATOR_USER..."
if [ -z "$OPERATOR_USER" ]; then
    log_warn "OPERATOR_USER not set, will use default: operator"
elif ! validate_username "$OPERATOR_USER"; then
    validation_error "OPERATOR_USER must match ^[a-z_][a-z0-9_-]*$ (got: $OPERATOR_USER)"
else
    validation_success "OPERATOR_USER=$OPERATOR_USER"
fi

# --- Validate GH_ACTIONS_USER ---
log_info "Validating GH_ACTIONS_USER..."
if [ -z "$GH_ACTIONS_USER" ]; then
    validation_error "GH_ACTIONS_USER is not set"
elif ! validate_username "$GH_ACTIONS_USER"; then
    validation_error "GH_ACTIONS_USER must match ^[a-z_][a-z0-9_-]*$ (got: $GH_ACTIONS_USER)"
else
    validation_success "GH_ACTIONS_USER=$GH_ACTIONS_USER"
fi

# --- Validate Boolean Flags ---
log_info "Validating optional component flags..."

validate_bool_flag() {
    local name=$1
    local value=$2

    if [ -z "$value" ]; then
        log_warn "$name not set, will use default: true"
    elif [ "$value" != "true" ] && [ "$value" != "false" ]; then
        validation_error "$name must be 'true' or 'false' (got: $value)"
    else
        validation_success "$name=$value"
    fi
}

validate_bool_flag "INSTALL_DOCKER" "$INSTALL_DOCKER"
validate_bool_flag "INSTALL_CADDY" "$INSTALL_CADDY"
validate_bool_flag "INSTALL_UNATTENDED_UPGRADES" "$INSTALL_UNATTENDED_UPGRADES"
validate_bool_flag "CREATE_APP_DIRECTORY" "$CREATE_APP_DIRECTORY"
validate_bool_flag "CONFIGURE_SWAP" "$CONFIGURE_SWAP"
validate_bool_flag "CONFIGURE_TIMEZONE" "$CONFIGURE_TIMEZONE"

# --- Validate SERVER_HOSTNAME (optional) ---
log_info "Validating SERVER_HOSTNAME..."
if [ -z "$SERVER_HOSTNAME" ]; then
    log_info "SERVER_HOSTNAME not set, hostname will not be changed"
elif ! [[ "$SERVER_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    validation_error "SERVER_HOSTNAME is invalid (got: $SERVER_HOSTNAME)"
else
    validation_success "SERVER_HOSTNAME=$SERVER_HOSTNAME"
fi

# --- Check for conflicting usernames ---
log_info "Checking for username conflicts..."
if [ -n "$OPERATOR_USER" ] && [ -n "$GH_ACTIONS_USER" ]; then
    if [ "$OPERATOR_USER" = "$GH_ACTIONS_USER" ]; then
        validation_error "OPERATOR_USER and GH_ACTIONS_USER cannot be the same"
    else
        validation_success "No username conflicts"
    fi
fi

# --- Summary ---
echo ""
if [ $ERRORS -gt 0 ]; then
    log_error "Configuration validation failed with $ERRORS error(s)"
    log_error "Please fix the errors in your .env file before continuing"
    exit 1
else
    print_complete "Configuration Validation Passed"
    log_success "All configuration values are valid"
fi

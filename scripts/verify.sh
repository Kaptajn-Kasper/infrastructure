#!/bin/bash
# Post-setup health check and verification script

# Don't use set -e as we want to continue even when checks fail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_env

print_header "Setup Verification"

CHECKS_PASSED=0
CHECKS_FAILED=0

# Check function - runs a command and reports pass/fail
check() {
    local name=$1
    shift

    if "$@" &>/dev/null; then
        echo -e "${GREEN}✓ PASS:${NC} $name"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL:${NC} $name"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

# Check with grep - for piped commands
check_grep() {
    local name=$1
    local pattern=$2
    shift 2

    if "$@" 2>/dev/null | grep -q "$pattern"; then
        echo -e "${GREEN}✓ PASS:${NC} $name"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL:${NC} $name"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

# ============================================
# Core Checks (always run)
# ============================================

log_step "Core System Checks"

# SSH on custom port
SSH_PORT_TO_CHECK="${SSH_PORT:-22}"
check_grep "SSH listening on port $SSH_PORT_TO_CHECK" ":$SSH_PORT_TO_CHECK" ss -tlnp

# UFW firewall
check_grep "UFW firewall is active" "Status: active" ufw status

# Operator user
OPERATOR="${OPERATOR_USER:-operator}"
check "Operator user '$OPERATOR' exists" id "$OPERATOR"

# Operator sudo access
check "Operator has sudo access" test -f "/etc/sudoers.d/$OPERATOR"

# GitHub Actions user
if [ -n "$GH_ACTIONS_USER" ]; then
    check "GitHub Actions user '$GH_ACTIONS_USER' exists" id "$GH_ACTIONS_USER"
    check "GitHub Actions user has limited sudo" test -f "/etc/sudoers.d/$GH_ACTIONS_USER"
fi

# GitHub SSH key
OPERATOR_HOME=$(get_user_home "$OPERATOR")
check "GitHub SSH key exists" test -f "$OPERATOR_HOME/.ssh/github_ed25519"

# Timezone
if [ "${CONFIGURE_TIMEZONE:-true}" = "true" ]; then
    check_grep "Timezone is UTC" "UTC" timedatectl show --property=Timezone --value
fi

# Swap
if [ "${CONFIGURE_SWAP:-true}" = "true" ]; then
    SWAP_SIZE=$(free -m | awk '/^Swap:/ {print $2}')
    if [ "$SWAP_SIZE" -gt 0 ] 2>/dev/null; then
        echo -e "${GREEN}✓ PASS:${NC} Swap is configured (${SWAP_SIZE}MB)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL:${NC} Swap is configured"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
fi

# ============================================
# Optional Component Checks
# ============================================

log_step "Optional Component Checks"

# Docker
if [ "${INSTALL_DOCKER:-true}" = "true" ]; then
    check "Docker is installed" command -v docker
    check "Docker service is running" systemctl is-active --quiet docker
    check "Docker Compose is available" docker compose version
fi

# Caddy (Docker)
if [ "${INSTALL_CADDY:-true}" = "true" ]; then
    check_grep "Caddy container is running" "caddy" docker ps -q -f name=^caddy$ -f status=running
    check "Caddy config exists" test -f /opt/apps/caddy/Caddyfile
fi

# Unattended Upgrades
if [ "${INSTALL_UNATTENDED_UPGRADES:-true}" = "true" ]; then
    check_grep "unattended-upgrades is installed" "^ii" dpkg -l unattended-upgrades
    check "unattended-upgrades service is running" systemctl is-active --quiet unattended-upgrades
fi

# App Directory
if [ "${CREATE_APP_DIRECTORY:-true}" = "true" ]; then
    check "/opt/apps directory exists" test -d /opt/apps
    check "/opt/apps/data directory exists" test -d /opt/apps/data
    if command -v docker &>/dev/null; then
        check_grep "caddy-network Docker network exists" "caddy-network" docker network ls
    fi
fi

# ============================================
# Network Connectivity Checks
# ============================================

log_step "Network Connectivity"

check "Can resolve DNS (github.com)" host github.com
check "Can reach the internet (curl)" curl -s --max-time 5 https://github.com -o /dev/null

# ============================================
# Summary
# ============================================

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "Verification Summary: ${GREEN}$CHECKS_PASSED passed${NC}, ${RED}$CHECKS_FAILED failed${NC}"
echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          All Verification Checks Passed!                   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Quick Reference:${NC}"
    echo -e "  SSH:      ${GREEN}ssh -p $SSH_PORT_TO_CHECK $OPERATOR@$(hostname -I | awk '{print $1}')${NC}"
    if [ "${INSTALL_DOCKER:-true}" = "true" ]; then
        echo -e "  Docker:   ${GREEN}docker run hello-world${NC}"
    fi
    if [ "${INSTALL_CADDY:-true}" = "true" ]; then
        echo -e "  Caddy:    ${GREEN}docker ps -f name=caddy${NC}"
    fi
    if [ "${CREATE_APP_DIRECTORY:-true}" = "true" ]; then
        echo -e "  Apps:     ${GREEN}cd /opt/apps${NC}"
    fi
    echo ""
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║          Some Verification Checks Failed                   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Review the failed checks above and troubleshoot as needed.${NC}"
    echo -e "${YELLOW}See docs/TROUBLESHOOTING.md for common issues.${NC}"
    echo ""
    exit 1
fi

#!/bin/bash
# Infrastructure Setup Orchestrator
# Runs all core and optional setup scripts in sequence

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/scripts/lib/common.sh"

# Setup logging
LOG_DIR="/var/log/infrastructure-setup"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d_%H%M%S).log"
export LOG_FILE

# Check if running as root
require_root

# Load environment variables
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo -e "${YELLOW}Please copy .env.template to .env and customize it:${NC}"
    echo -e "  cp .env.template .env"
    echo -e "  nano .env"
    exit 1
fi

source "$SCRIPT_DIR/.env"

# Print header
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Infrastructure Setup Orchestrator                ║${NC}"
echo -e "${BLUE}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC}  Log file: ${YELLOW}$LOG_FILE${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Track success/failure
SUCCESS_COUNT=0
FAIL_COUNT=0
SCRIPTS_RUN=()

# Function to run a setup script
run_script() {
    local script_path=$1
    local script_name=$(basename "$script_path")

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Running: $script_name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ ! -f "$script_path" ]; then
        echo -e "${RED}Error: Script not found: $script_path${NC}"
        ((FAIL_COUNT++))
        SCRIPTS_RUN+=("${RED}✗${NC} $script_name - NOT FOUND")
        return 1
    fi

    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi

    # Run the script and capture exit code
    if bash "$script_path" 2>&1 | tee -a "$LOG_FILE"; then
        ((SUCCESS_COUNT++))
        SCRIPTS_RUN+=("${GREEN}✓${NC} $script_name")
        echo -e "${GREEN}✓ $script_name completed successfully${NC}"
    else
        ((FAIL_COUNT++))
        SCRIPTS_RUN+=("${RED}✗${NC} $script_name - FAILED")
        echo -e "${RED}✗ $script_name failed${NC}"
        return 1
    fi

    echo ""
}

# ============================================
# Run Core Scripts (always run)
# ============================================

echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                     CORE CONFIGURATION                        ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

for script in "$SCRIPT_DIR/scripts/core/"*.sh; do
    run_script "$script" || true
done

# ============================================
# Run Optional Scripts (based on .env flags)
# ============================================

echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                   OPTIONAL COMPONENTS                         ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Docker
if [ "${INSTALL_DOCKER:-true}" = "true" ]; then
    run_script "$SCRIPT_DIR/scripts/optional/docker.sh" || true
else
    echo -e "${YELLOW}Skipping Docker installation (INSTALL_DOCKER=false)${NC}"
    echo ""
fi

# Caddy
if [ "${INSTALL_CADDY:-true}" = "true" ]; then
    run_script "$SCRIPT_DIR/scripts/optional/caddy.sh" || true
else
    echo -e "${YELLOW}Skipping Caddy installation (INSTALL_CADDY=false)${NC}"
    echo ""
fi

# Unattended Upgrades
if [ "${INSTALL_UNATTENDED_UPGRADES:-true}" = "true" ]; then
    run_script "$SCRIPT_DIR/scripts/optional/unattended-upgrades.sh" || true
else
    echo -e "${YELLOW}Skipping unattended-upgrades (INSTALL_UNATTENDED_UPGRADES=false)${NC}"
    echo ""
fi

# App Directory
if [ "${CREATE_APP_DIRECTORY:-true}" = "true" ]; then
    run_script "$SCRIPT_DIR/scripts/optional/app-directory.sh" || true
else
    echo -e "${YELLOW}Skipping app directory creation (CREATE_APP_DIRECTORY=false)${NC}"
    echo ""
fi

# ============================================
# Run Verification
# ============================================

echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                       VERIFICATION                            ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [ -f "$SCRIPT_DIR/scripts/verify.sh" ]; then
    run_script "$SCRIPT_DIR/scripts/verify.sh" || true
fi

# ============================================
# Summary
# ============================================

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                     Setup Summary                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

for result in "${SCRIPTS_RUN[@]}"; do
    echo -e "  $result"
done

echo ""
echo -e "Total: ${GREEN}$SUCCESS_COUNT succeeded${NC}, ${RED}$FAIL_COUNT failed${NC}"
echo ""
echo -e "${BLUE}Log file:${NC} $LOG_FILE"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          All Setup Scripts Completed Successfully!         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Some Setup Scripts Failed                     ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Check the log file for details: $LOG_FILE${NC}"
    exit 1
fi

#!/bin/bash
# Setup custom SSH welcome screen (MOTD)

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

print_header "Welcome Screen Setup"

MOTD_DIR="/etc/update-motd.d"
MOTD_FILE="$MOTD_DIR/00-kaptajn-kasper"

# Check if update-motd.d directory exists
if [ ! -d "$MOTD_DIR" ]; then
    log_info "Creating $MOTD_DIR directory..."
    mkdir -p "$MOTD_DIR"
    log_success "Created $MOTD_DIR"
fi

# Disable default MOTD components if they exist
log_info "Configuring MOTD components..."
for script in 10-help-text 50-motd-news 90-updates-available 91-release-upgrade; do
    if [ -x "$MOTD_DIR/$script" ]; then
        chmod -x "$MOTD_DIR/$script" 2>/dev/null || true
        log_success "Disabled $script"
    fi
done

# Create the branded welcome screen
log_info "Creating welcome screen..."

cat > "$MOTD_FILE" << 'MOTD_SCRIPT'
#!/bin/bash

# Colors
CYAN='\033[0;36m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
WHITE='\033[1;37m'
NC='\033[0m'

echo ""
echo -e "${CYAN}    _  __            _        _           _  __                          ${NC}"
echo -e "${CYAN}   | |/ /__ _ _ __  | |_ __ _(_)_ __     | |/ /__ _ ___ _ __   ___ _ __  ${NC}"
echo -e "${CYAN}   | ' // _\` | '_ \ | __/ _\` | | '_ \    | ' // _\` / __| '_ \ / _ \ '__| ${NC}"
echo -e "${CYAN}   | . \ (_| | |_) || || (_| | | | | |   | . \ (_| \__ \ |_) |  __/ |    ${NC}"
echo -e "${CYAN}   |_|\_\__,_| .__/  \__\__,_|_|_| |_|   |_|\_\__,_|___/ .__/ \___|_|    ${NC}"
echo -e "${CYAN}             |_|                                      |_|               ${NC}"
echo ""
echo -e "${BLUE}   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
echo -e "${WHITE}                    Infrastructure Server${NC}"
echo -e "${BLUE}   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
echo ""
echo -e "${YELLOW}       _~_${NC}"
echo -e "${YELLOW}    .-'   '-.${NC}"
echo -e "${YELLOW}   /  .---.  \\${NC}      ${GREEN}Hostname:${NC}  $(hostname)"
echo -e "${YELLOW}  |  / ___ \  |${NC}     ${GREEN}IP:${NC}        $(hostname -I | awk '{print $1}')"
echo -e "${YELLOW}  | | |   | | |${NC}     ${GREEN}Uptime:${NC}    $(uptime -p | sed 's/up //')"
echo -e "${YELLOW}  | | |   | | |${NC}     ${GREEN}Load:${NC}      $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
echo -e "${YELLOW}  |  \_____/  |${NC}     ${GREEN}Memory:${NC}    $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
echo -e "${YELLOW}   \  '---'  /${NC}      ${GREEN}Disk:${NC}      $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')"
echo -e "${YELLOW}    '-._____.-'${NC}"
echo ""
echo -e "${BLUE}   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
echo -e "${WHITE}              Welcome aboard, Captain!${NC}"
echo -e "${BLUE}   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
echo ""
MOTD_SCRIPT

# Make the script executable
chmod +x "$MOTD_FILE"
log_success "Created and enabled welcome screen"

# Ensure MOTD is displayed on login
PAM_SSHD="/etc/pam.d/sshd"
if [ -f "$PAM_SSHD" ]; then
    if grep -q "pam_motd.so" "$PAM_SSHD"; then
        log_success "PAM MOTD configuration verified"
    else
        log_warn "MOTD not configured in PAM. This is usually already set up."
    fi
fi

# Disable static MOTD if it exists and has content
STATIC_MOTD="/etc/motd"
if [ -f "$STATIC_MOTD" ] && [ -s "$STATIC_MOTD" ]; then
    log_info "Clearing static MOTD file..."
    echo "" > "$STATIC_MOTD"
    log_success "Static MOTD cleared"
fi

print_complete "Welcome Screen Setup Complete"

echo -e "${YELLOW}Preview of the welcome screen:${NC}"
echo ""
bash "$MOTD_FILE"

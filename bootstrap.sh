#!/usr/bin/env bash
# bootstrap.sh — turn a fresh Ubuntu 24.04 server into the app host. Safe to re-run.
#
# Run as root on a freshly installed or rebuilt server:
#
#   git clone https://github.com/Kaptajn-Kasper/infrastructure.git /srv/infra
#   /srv/infra/bootstrap.sh [--ssh-key "ssh-ed25519 AAAA… you@laptop"] [--runner-token TOKEN]
#
#   --ssh-key       public key for the admin user (default: copy root's authorized_keys)
#   --runner-token  GitHub runner registration token; registers the runner when given
#
# It creates the admin and runner users, hardens SSH (key-only, no root login),
# installs Docker and unattended-upgrades, adds swap, then runs bin/infra-apply.
set -euo pipefail

ADMIN_USER="admin"
INFRA_DIR=/srv/infra
REPO_URL=https://github.com/Kaptajn-Kasper/infrastructure.git

log() { echo "bootstrap: $*"; }
die() { echo "bootstrap: $*" >&2; exit 1; }

ssh_key=""
runner_token=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-key) ssh_key=${2:?--ssh-key needs a value}; shift 2 ;;
    --runner-token) runner_token=${2:?--runner-token needs a value}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must run as root"
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu ]] || die "expected Ubuntu, found $ID"

export DEBIAN_FRONTEND=noninteractive

# --- Packages ----------------------------------------------------------------
log "updating packages"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl git jq unattended-upgrades

# Skip if a Docker repo is already configured (e.g. Hetzner's "Docker CE" image);
# a second entry with a different key path makes apt refuse to run.
if ! grep -rqs download.docker.com /etc/apt/sources.list /etc/apt/sources.list.d/; then
  log "adding the Docker apt repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
fi
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

install -d -m 0755 /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "live-restore": true
}
EOF
systemctl enable -q docker
systemctl restart docker

# --- Users -------------------------------------------------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  log "creating user $ADMIN_USER"
  useradd --create-home --shell /bin/bash "$ADMIN_USER"
fi
usermod -aG sudo,docker "$ADMIN_USER"
passwd -l "$ADMIN_USER" >/dev/null
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-admin
chmod 0440 /etc/sudoers.d/90-admin
visudo -cqf /etc/sudoers.d/90-admin || die "invalid sudoers rule for $ADMIN_USER"

admin_ssh=/home/$ADMIN_USER/.ssh
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$admin_ssh"
if [[ -n $ssh_key ]]; then
  echo "$ssh_key" >"$admin_ssh/authorized_keys"
elif [[ ! -s $admin_ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "$admin_ssh/authorized_keys"
fi
[[ -s $admin_ssh/authorized_keys ]] \
  || die "no SSH key for $ADMIN_USER; pass --ssh-key \"ssh-ed25519 …\" (SSH is not changed yet)"
chown "$ADMIN_USER:$ADMIN_USER" "$admin_ssh/authorized_keys"
chmod 0600 "$admin_ssh/authorized_keys"

if ! id runner >/dev/null 2>&1; then
  log "creating user runner"
  useradd --system --home-dir /opt/actions-runner --shell /bin/bash runner
fi
passwd -l runner >/dev/null

# --- SSH ---------------------------------------------------------------------
# Sorts before Ubuntu's/Hetzner's 50-cloud-init.conf; sshd uses the first value set.
cat >/etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $ADMIN_USER
EOF
sshd -t || die "sshd config test failed"
systemctl restart ssh
log "SSH: key-only, root login disabled, only $ADMIN_USER allowed"

# --- Automatic updates -------------------------------------------------------
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

# --- Swap --------------------------------------------------------------------
if [[ -z $(swapon --show --noheadings) ]]; then
  log "adding 2G swap"
  fallocate -l 2G /swapfile
  chmod 0600 /swapfile
  mkswap -q /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# --- Weekly image cleanup ----------------------------------------------------
cat >/etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Remove unused Docker images older than a week

[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -af --filter until=168h
EOF
cat >/etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Weekly Docker image prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable -q --now docker-prune.timer

# --- Infra repo, Caddy, runner -----------------------------------------------
if [[ ! -d $INFRA_DIR/.git ]]; then
  git clone -q "$REPO_URL" "$INFRA_DIR"
fi
"$INFRA_DIR/bin/infra-apply"

if [[ -n $runner_token ]]; then
  "$INFRA_DIR/bin/install-runner" "$runner_token"
fi

log "done. Before closing this session, check in a new terminal: ssh $ADMIN_USER@<server-ip>"

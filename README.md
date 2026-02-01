# Infrastructure

Automated infrastructure setup for quickly provisioning Ubuntu VPS instances for Docker Compose application deployment with Caddy reverse proxy.

**Philosophy**: Make it easier to spin up a new server than to fix a broken one.

## Quick Start

### Manual Setup (SSH)

```bash
# 1. Clone the repository on your server
git clone https://github.com/YOUR_USER/infrastructure.git
cd infrastructure

# 2. Create and customize your configuration
cp .env.template .env
nano .env

# 3. Run the setup (as root)
sudo ./setup.sh
```

### Cloud-Init Setup

Paste the following into your VPS provider's "User Data" field:

```bash
#!/bin/bash
export GITHUB_REPO="https://github.com/YOUR_USER/infrastructure.git"
export SSH_PORT=22022
export OPERATOR_USER=operator
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/infrastructure/main/bootstrap.sh | bash
```

## What Gets Installed

### Core (Always)

| Component | Description |
|-----------|-------------|
| SSH Hardening | Custom port, rate limiting |
| UFW Firewall | Deny incoming, allow SSH/HTTP/HTTPS |
| Operator User | Daily admin with full sudo |
| GH Actions User | CI/CD user with limited sudo |
| GitHub SSH | SSH key + gh CLI |
| System Config | UTC timezone, swap, locale |
| Welcome Screen | Custom MOTD |

### Optional (Configurable via .env)

| Component | Flag | Default |
|-----------|------|---------|
| Docker + Compose | `INSTALL_DOCKER` | `true` |
| Caddy | `INSTALL_CADDY` | `true` |
| Auto Updates | `INSTALL_UNATTENDED_UPGRADES` | `true` |
| App Directory | `CREATE_APP_DIRECTORY` | `true` |

## Directory Structure

```
infrastructure/
├── setup.sh                 # Main orchestrator
├── bootstrap.sh             # Cloud-init bootstrap
├── .env.template            # Configuration template
├── .env                     # Your configuration (gitignored)
│
├── scripts/
│   ├── lib/
│   │   └── common.sh        # Shared functions
│   │
│   ├── core/                # Always-run scripts
│   │   ├── 00-validate-config.sh
│   │   ├── 01-configure-system.sh
│   │   ├── 02-change-ssh-port.sh
│   │   ├── 03-configure-firewall.sh
│   │   ├── 04-create-operator.sh
│   │   ├── 05-setup-github-ssh.sh
│   │   ├── 06-create-gh-actions.sh
│   │   └── 07-setup-motd.sh
│   │
│   ├── optional/            # Conditionally-run scripts
│   │   ├── docker.sh
│   │   ├── caddy.sh
│   │   ├── unattended-upgrades.sh
│   │   └── app-directory.sh
│   │
│   └── verify.sh            # Post-setup health check
│
└── docs/
    ├── CONFIGURATION.md     # Detailed config docs
    └── TROUBLESHOOTING.md   # Common issues
```

## Configuration

Copy `.env.template` to `.env` and customize:

```bash
# SSH Configuration
SSH_PORT=22022

# User Accounts
OPERATOR_USER=operator
GH_ACTIONS_USER=gh-actions

# Optional Components (true/false)
INSTALL_DOCKER=true
INSTALL_CADDY=true
INSTALL_UNATTENDED_UPGRADES=true
CREATE_APP_DIRECTORY=true

# System Configuration
CONFIGURE_SWAP=true
CONFIGURE_TIMEZONE=true
SERVER_HOSTNAME=myserver
```

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for detailed documentation.

## After Setup

### 1. Test SSH Connection

```bash
# From your local machine (in a new terminal!)
ssh -p 22022 operator@your-server-ip
```

### 2. Add GitHub SSH Key

The setup displays a public key. Add it to GitHub:
1. Go to https://github.com/settings/ssh/new
2. Paste the public key
3. Test: `ssh -T git@github.com`

### 3. Deploy Your First App

```bash
cd /opt/apps
git clone git@github.com:your/app.git myapp
cd myapp
docker compose up -d
```

### 4. Configure Caddy

Edit `/etc/caddy/Caddyfile`:

```
myapp.example.com {
    reverse_proxy localhost:3000
}
```

```bash
sudo systemctl reload caddy
```

## Verification

Run the health check to verify everything is working:

```bash
sudo /path/to/infrastructure/scripts/verify.sh
```

## Security Features

- **SSH Hardening**: Non-standard port, rate limiting (blocks after 6 attempts in 30s)
- **Firewall**: UFW with deny-by-default, only SSH/HTTP/HTTPS open
- **Auto Updates**: Automatic security patches via unattended-upgrades
- **Least Privilege**: GH Actions user has limited sudo (docker + systemctl only)
- **Operator Convenience**: Full NOPASSWD sudo for daily operations

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues and solutions.

### Quick Fixes

**Locked out of SSH?**
```bash
# Use VPS console to restore port 22
sudo ufw allow 22/tcp
sudo sed -i 's/Port .*/Port 22/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

**Docker permission denied?**
```bash
# Re-login to apply group membership
exit
ssh -p 22022 operator@server
```

## Logs

Setup logs are stored in `/var/log/infrastructure-setup/`:

```bash
ls -la /var/log/infrastructure-setup/
cat /var/log/infrastructure-setup/setup-*.log
```

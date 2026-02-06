# Troubleshooting Guide

This guide covers common issues and their solutions.

## SSH Issues

### Locked Out of SSH

**Symptom**: Can't connect via SSH after setup.

**Cause**: Usually SSH port change or firewall misconfiguration.

**Solution**:

1. **Use VPS Console**: Most providers offer web-based console access.

2. **Restore SSH access**:
   ```bash
   # As root via console
   sudo ufw allow 22/tcp
   sudo sed -i 's/Port .*/Port 22/' /etc/ssh/sshd_config
   sudo systemctl restart ssh
   ```

3. **Verify firewall rules**:
   ```bash
   sudo ufw status numbered
   ```

4. **Check SSH is listening**:
   ```bash
   sudo ss -tlnp | grep ssh
   ```

**Prevention**: Always test new SSH port in a separate terminal before closing your current session.

---

### SSH Connection Timeout

**Symptom**: SSH connection hangs or times out.

**Cause**: Firewall blocking, wrong port, or network issues.

**Solution**:

1. **Verify the port**:
   ```bash
   # Check what port SSH is configured to use
   grep "^Port" /etc/ssh/sshd_config
   ```

2. **Check firewall allows the port**:
   ```bash
   sudo ufw status | grep <port>
   ```

3. **Test from your machine**:
   ```bash
   # Test if port is reachable
   nc -zv your-server-ip 22022
   ```

4. **Check SSH service is running**:
   ```bash
   sudo systemctl status ssh
   ```

---

### Permission Denied (publickey)

**Symptom**: `Permission denied (publickey)` when connecting.

**Cause**: SSH key not in authorized_keys or wrong permissions.

**Solution**:

1. **Add your public key**:
   ```bash
   # On the server (via console)
   echo "your-public-key-here" >> /home/operator/.ssh/authorized_keys
   chmod 600 /home/operator/.ssh/authorized_keys
   chown operator:operator /home/operator/.ssh/authorized_keys
   ```

2. **Check permissions**:
   ```bash
   ls -la /home/operator/.ssh/
   # Should show:
   # drwx------ .ssh
   # -rw------- authorized_keys
   ```

3. **Verify key format**: Ensure the key is on a single line and properly formatted.

---

## Docker Issues

### Permission Denied

**Symptom**: `permission denied while trying to connect to the Docker daemon socket`

**Cause**: User not in docker group or need to re-login.

**Solution**:

1. **Check group membership**:
   ```bash
   groups
   # Should include 'docker'
   ```

2. **If docker group missing, add it**:
   ```bash
   sudo usermod -aG docker $USER
   ```

3. **Re-login to apply changes**:
   ```bash
   exit
   ssh -p 22022 operator@server
   ```

4. **Verify**:
   ```bash
   docker run hello-world
   ```

---

### Docker Service Won't Start

**Symptom**: Docker service fails to start.

**Solution**:

1. **Check status and logs**:
   ```bash
   sudo systemctl status docker
   sudo journalctl -xeu docker
   ```

2. **Common fixes**:
   ```bash
   # Reset Docker
   sudo systemctl stop docker
   sudo rm -rf /var/lib/docker/tmp/*
   sudo systemctl start docker
   ```

3. **Check disk space**:
   ```bash
   df -h
   # Docker needs space in /var/lib/docker
   ```

---

### Cannot Pull Images

**Symptom**: `error pulling image` or DNS resolution failures.

**Solution**:

1. **Check DNS**:
   ```bash
   host docker.io
   ```

2. **Check Docker daemon config**:
   ```bash
   cat /etc/docker/daemon.json
   ```

3. **Try with explicit DNS**:
   ```bash
   # Edit /etc/docker/daemon.json
   {
     "dns": ["8.8.8.8", "8.8.4.4"]
   }
   sudo systemctl restart docker
   ```

---

## Caddy Issues

### Caddy Won't Start

**Symptom**: Caddy service fails to start.

**Solution**:

1. **Check configuration syntax**:
   ```bash
   sudo caddy validate --config /etc/caddy/Caddyfile
   ```

2. **Check logs**:
   ```bash
   sudo journalctl -xeu caddy
   ```

3. **Common issues**:
   - Port 80/443 already in use (Apache, nginx)
   - Invalid domain configuration
   - Permission issues

4. **Check port conflicts**:
   ```bash
   sudo ss -tlnp | grep -E ':80|:443'
   ```

---

### Certificate Issues

**Symptom**: HTTPS not working, certificate errors.

**Cause**: Usually DNS not pointing to server, or firewall blocking ports.

**Solution**:

1. **Verify DNS**:
   ```bash
   host yourdomain.com
   # Should return your server's IP
   ```

2. **Check firewall**:
   ```bash
   sudo ufw status | grep -E '80|443'
   # Both should be ALLOW
   ```

3. **Check Caddy logs**:
   ```bash
   sudo journalctl -u caddy | grep -i cert
   ```

4. **Test HTTP access**:
   ```bash
   curl -v http://yourdomain.com
   ```

---

## Firewall Issues

### Can't Access Services

**Symptom**: External services (web, database) not reachable.

**Solution**:

1. **Check current rules**:
   ```bash
   sudo ufw status numbered
   ```

2. **Add rule for service**:
   ```bash
   sudo ufw allow 3000/tcp comment "My App"
   ```

3. **Verify service is listening**:
   ```bash
   sudo ss -tlnp | grep 3000
   ```

---

### UFW Locked Me Out

**Symptom**: All network access blocked.

**Solution** (via VPS console):

1. **Disable UFW temporarily**:
   ```bash
   sudo ufw disable
   ```

2. **Reset to defaults**:
   ```bash
   sudo ufw reset
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow 22/tcp  # or your SSH port
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw enable
   ```

---

## User/Permission Issues

### Sudo Not Working

**Symptom**: `user is not in the sudoers file`

**Solution**:

1. **Check sudoers file exists**:
   ```bash
   ls -la /etc/sudoers.d/
   ```

2. **Recreate if missing** (as root via console):
   ```bash
   echo "operator ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/operator
   chmod 440 /etc/sudoers.d/operator
   visudo -c
   ```

---

### GitHub SSH Key Not Working

**Symptom**: `Permission denied (publickey)` when connecting to GitHub.

**Solution**:

1. **Check key exists**:
   ```bash
   ls -la ~/.ssh/github_ed25519
   ```

2. **Test connection**:
   ```bash
   ssh -vT git@github.com
   ```

3. **Verify key is added to GitHub**:
   - Go to https://github.com/settings/keys
   - Ensure the key is listed

4. **Check SSH config**:
   ```bash
   cat ~/.ssh/config
   # Should have Host github.com section
   ```

---

## App Deployment Issues

### App Failed to Clone

**Symptom**: `deploy-apps` reports "Failed to clone" for an app.

**Cause**: SSH key not registered with GitHub, or repo doesn't exist.

**Solution**:

1. **Test GitHub SSH access**:
   ```bash
   ssh -T git@github.com
   ```

2. **Verify the repo exists and you have access**:
   ```bash
   gh repo view Kaptajn-Kasper/myapp
   ```

3. **Check SSH key is registered**:
   - Go to https://github.com/settings/keys
   - Ensure the server's key is listed

4. **Check SSH config**:
   ```bash
   cat ~/.ssh/config
   # Should have Host github.com with IdentityFile pointing to your key
   ```

---

### Caddy Validation Failed After Deploy

**Symptom**: `deploy-apps` warns "Caddy config validation failed — not reloading".

**Cause**: A `Caddyfile.snippet` in one of your app repos has syntax errors.

**Solution**:

1. **Run validation to see the error**:
   ```bash
   sudo caddy validate --config /etc/caddy/Caddyfile
   ```

2. **Check the snippet that was just copied**:
   ```bash
   ls -la /etc/caddy/conf.d/
   # Review the most recently modified .caddy file
   ```

3. **Fix the snippet in the app repo**, then re-deploy:
   ```bash
   deploy-apps --app <name>
   ```

---

### App Container Won't Start

**Symptom**: `deploy-apps` succeeds but the app isn't accessible.

**Solution**:

1. **Check container status**:
   ```bash
   cd /opt/apps/myapp
   docker compose ps
   ```

2. **Check container logs**:
   ```bash
   docker compose logs
   ```

3. **Check for missing config files**:
   ```bash
   # See what was seeded on first deploy
   ls -la /opt/apps/configs/myapp/
   # Edit with real values, then re-deploy
   deploy-apps --app myapp
   ```

4. **Check the app is on the caddy-network**:
   ```bash
   docker network inspect caddy-network
   ```

---

### Build fails with missing environment/config file

**Symptom**: Docker build fails because a config file (e.g., `environment.prod.ts`, `.env`) is missing.

**Cause**: The config was not seeded on first deploy, or the app expects files that don't have a matching example file in the repo.

**Solution**:

1. **Check what's in the config directory**:
   ```bash
   find /opt/apps/configs/myapp/ -type f
   ```

2. **Add the missing file manually**:
   ```bash
   # Create the file at the relative path the app expects
   mkdir -p /opt/apps/configs/myapp/src/environments
   cp /opt/apps/myapp/src/environments/environment.example.ts \
      /opt/apps/configs/myapp/src/environments/environment.prod.ts
   # Edit with real values
   ```

3. **Re-deploy**:
   ```bash
   deploy-apps --app myapp
   ```

---

### deploy-apps: command not found

**Symptom**: Running `deploy-apps` returns "command not found".

**Cause**: The symlink to `/usr/local/bin/deploy-apps` was not created.

**Solution**:

1. **Re-run the app-directory setup**:
   ```bash
   sudo /root/infrastructure/scripts/optional/app-directory.sh
   ```

2. **Or create the symlink manually**:
   ```bash
   sudo ln -sf /root/infrastructure/scripts/deploy-apps.sh /usr/local/bin/deploy-apps
   ```

---

## System Issues

### Out of Disk Space

**Symptom**: Operations failing, "no space left on device"

**Solution**:

1. **Check disk usage**:
   ```bash
   df -h
   du -sh /* 2>/dev/null | sort -h
   ```

2. **Clean Docker**:
   ```bash
   docker system prune -a
   ```

3. **Clean apt cache**:
   ```bash
   sudo apt-get clean
   sudo apt-get autoremove
   ```

4. **Clean old logs**:
   ```bash
   sudo journalctl --vacuum-time=7d
   ```

---

### Swap Not Working

**Symptom**: No swap space, or swap not being used.

**Solution**:

1. **Check swap status**:
   ```bash
   free -h
   swapon --show
   ```

2. **Create swap manually**:
   ```bash
   sudo fallocate -l 2G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   ```

---

## Getting Help

### Logs to Check

```bash
# Setup logs
ls -la /var/log/infrastructure-setup/
cat /var/log/infrastructure-setup/setup-*.log

# System logs
sudo journalctl -xe

# Service-specific logs
sudo journalctl -u docker
sudo journalctl -u caddy
sudo journalctl -u ssh
```

### Running Verification

```bash
sudo /path/to/infrastructure/scripts/verify.sh
```

### Re-running Setup

The setup scripts are idempotent - safe to run again:

```bash
cd /path/to/infrastructure
sudo ./setup.sh
```

### Reporting Issues

If you encounter a bug:
1. Check logs for error messages
2. Note which script failed
3. Open an issue with log output

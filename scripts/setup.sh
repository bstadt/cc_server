#!/bin/bash
#
# Claude Connect Server Setup Script
#
# Run this on a fresh Ubuntu 22.04+ EC2 instance to set up claudeconnect.io
#
# Usage:
#   1. Clone repo to instance: git clone https://github.com/bstadt/cc_server.git
#   2. cd cc_server
#   3. sudo ./scripts/setup.sh
#
# Prerequisites:
#   - Ubuntu 22.04 LTS (tested on t3.small)
#   - Domain pointing to instance IP (for SSL)
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root (sudo ./scripts/setup.sh)"
fi

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

log "Starting Claude Connect server setup..."
log "Repo directory: $REPO_DIR"

# =============================================================================
# 0. Load Environment Variables
# =============================================================================
ENV_FILE="$REPO_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    error ".env file not found at $ENV_FILE"
fi

log "Loading environment variables from .env..."
set -a  # Export all variables
source "$ENV_FILE"
set +a

# Validate required variables
[ -z "$GOOGLE_CLIENT_ID" ] && error "GOOGLE_CLIENT_ID not set in .env"
[ -z "$GOOGLE_CLIENT_SECRET" ] && error "GOOGLE_CLIENT_SECRET not set in .env"
[ -z "$FLASK_SECRET_KEY" ] && error "FLASK_SECRET_KEY not set in .env"
[ -z "$FERNET_KEY" ] && error "FERNET_KEY not set in .env"

log "Environment variables loaded successfully"

# =============================================================================
# 1. Install System Packages
# =============================================================================
log "Installing system packages..."

apt update
apt install -y \
    apache2 \
    libapache2-mod-svn \
    libapache2-mod-authnz-external \
    subversion \
    python3-venv \
    python3-pip \
    certbot \
    python3-certbot-apache \
    pwauth

# =============================================================================
# 2. Create Directory Structure
# =============================================================================
log "Creating directory structure..."

# Flask app directory
mkdir -p /opt/claudeconnect
chown ubuntu:ubuntu /opt/claudeconnect

# SVN repositories directory
mkdir -p /var/svn/repos
chown www-data:www-data /var/svn/repos
chmod 755 /var/svn/repos

# Ephemeral test users tracking file (owned by ubuntu for Flask app)
touch /var/svn/ephemeral-users.json
chown ubuntu:ubuntu /var/svn/ephemeral-users.json

# Landing page directory
mkdir -p /var/www/claudeconnect
chown www-data:www-data /var/www/claudeconnect

# =============================================================================
# 3. Copy Application Files
# =============================================================================
log "Copying application files..."

# Flask app
cp "$REPO_DIR/flask/app.py" /opt/claudeconnect/
cp "$REPO_DIR/flask/svn-auth.py" /opt/claudeconnect/
chmod +x /opt/claudeconnect/svn-auth.py
chown ubuntu:ubuntu /opt/claudeconnect/*.py

# Landing page
cp "$REPO_DIR/www/index.html" /var/www/claudeconnect/
chown www-data:www-data /var/www/claudeconnect/index.html

# =============================================================================
# 4. Set Up Python Virtual Environment
# =============================================================================
log "Setting up Python virtual environment..."

cd /opt/claudeconnect
sudo -u ubuntu python3 -m venv venv
sudo -u ubuntu /opt/claudeconnect/venv/bin/pip install --upgrade pip
sudo -u ubuntu /opt/claudeconnect/venv/bin/pip install flask authlib httpx cryptography requests

# =============================================================================
# 5. Store Fernet Key
# =============================================================================
log "Storing Fernet key..."

echo "$FERNET_KEY" > /opt/claudeconnect/fernet.key
chmod 600 /opt/claudeconnect/fernet.key
chown www-data:www-data /opt/claudeconnect/fernet.key  # www-data needs to read for svn-auth.py

log "Fernet key stored at /opt/claudeconnect/fernet.key"

# =============================================================================
# 6. Configure Apache
# =============================================================================
log "Configuring Apache..."

# Enable required modules
a2enmod ssl proxy proxy_http headers dav dav_svn authz_svn authnz_external rewrite

# Disable default site
a2dissite 000-default.conf 2>/dev/null || true

# Copy Apache config (HTTP-only version first for certbot)
cat > /etc/apache2/sites-available/claudeconnect-http.conf << 'HTTPCONF'
<VirtualHost *:80>
    ServerName claudeconnect.io
    ServerAlias www.claudeconnect.io

    DocumentRoot /var/www/claudeconnect
    <Directory /var/www/claudeconnect>
        Require all granted
    </Directory>
</VirtualHost>
HTTPCONF

# Enable HTTP site (needed for certbot)
a2ensite claudeconnect-http.conf

# Restart Apache
systemctl restart apache2

log "Apache configured with HTTP-only site (for certbot)"

# =============================================================================
# 7. SSL Certificate (Interactive)
# =============================================================================
echo ""
warn "=============================================="
warn "SSL CERTIFICATE SETUP"
warn "=============================================="
echo ""
echo "Before continuing, ensure:"
echo "  1. Your domain (claudeconnect.io) points to this server's IP"
echo "  2. Security group allows inbound ports 80 and 443"
echo ""
read -p "Ready to obtain SSL certificate? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Running certbot..."
    certbot --apache -d claudeconnect.io -d www.claudeconnect.io --non-interactive --agree-tos --email admin@claudeconnect.io || {
        warn "Certbot failed. You can run it manually later:"
        warn "  sudo certbot --apache -d claudeconnect.io -d www.claudeconnect.io"
    }
else
    warn "Skipping SSL setup. Run certbot manually later."
fi

# =============================================================================
# 8. Install Full Apache Config
# =============================================================================
log "Installing full Apache configuration..."

# Create the full config with SSL
cat > /etc/apache2/sites-available/claudeconnect.conf << APACHECONF
<VirtualHost *:80>
    ServerName claudeconnect.io
    ServerAlias www.claudeconnect.io
    Redirect permanent / https://claudeconnect.io/
</VirtualHost>

<VirtualHost *:443>
    ServerName claudeconnect.io
    ServerAlias www.claudeconnect.io

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/claudeconnect.io/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/claudeconnect.io/privkey.pem

    # Set FERNET_KEY for auth script
    SetEnv FERNET_KEY "$FERNET_KEY"

    # Landing page (static)
    DocumentRoot /var/www/claudeconnect
    <Directory /var/www/claudeconnect>
        Require all granted
    </Directory>

    # Proxy headers for Flask
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Host "claudeconnect.io"

    # Proxy auth endpoints to Flask
    ProxyPreserveHost On
    ProxyPass /login http://127.0.0.1:5000/login
    ProxyPassReverse /login http://127.0.0.1:5000/login
    ProxyPass /callback http://127.0.0.1:5000/callback
    ProxyPassReverse /callback http://127.0.0.1:5000/callback
    ProxyPass /refresh http://127.0.0.1:5000/refresh
    ProxyPassReverse /refresh http://127.0.0.1:5000/refresh

    # Proxy API endpoints to Flask
    ProxyPass /api http://127.0.0.1:5000/api
    ProxyPassReverse /api http://127.0.0.1:5000/api

    # SVN with Fernet token auth via external script
    DefineExternalAuth svn_fernet pipe "/opt/claudeconnect/svn-auth.py"

    <Location /svn>
        DAV svn
        SVNParentPath /var/svn/repos
        SVNPathAuthz short_circuit
        AuthzSVNReposRelativeAccessFile authz

        AuthType Basic
        AuthName "Claude Connect SVN"
        AuthBasicProvider external
        AuthExternal svn_fernet

        Require valid-user
    </Location>
</VirtualHost>
APACHECONF

# Disable HTTP-only site, enable full site
a2dissite claudeconnect-http.conf 2>/dev/null || true
a2ensite claudeconnect.conf

# =============================================================================
# 9. Configure Systemd Service
# =============================================================================
log "Configuring systemd service..."

# Create systemd service
cat > /etc/systemd/system/claudeconnect.service << SYSTEMD
[Unit]
Description=Claude Connect API
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/opt/claudeconnect
Environment="GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID"
Environment="GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET"
Environment="FLASK_SECRET_KEY=$FLASK_SECRET_KEY"
Environment="FERNET_KEY=$FERNET_KEY"
ExecStart=/opt/claudeconnect/venv/bin/python /opt/claudeconnect/app.py
Restart=always

[Install]
WantedBy=multi-user.target
SYSTEMD

# Reload and start service
systemctl daemon-reload
systemctl enable claudeconnect
systemctl start claudeconnect

# =============================================================================
# 10. Final Apache Restart
# =============================================================================
log "Restarting Apache..."
systemctl restart apache2

# =============================================================================
# Done!
# =============================================================================
echo ""
echo -e "${GREEN}=============================================="
echo "SETUP COMPLETE!"
echo "==============================================${NC}"
echo ""
echo "Services:"
echo "  - Apache: systemctl status apache2"
echo "  - Flask:  systemctl status claudeconnect"
echo ""
echo "Logs:"
echo "  - Flask:  journalctl -u claudeconnect -f"
echo "  - Apache: tail -f /var/log/apache2/error.log"
echo ""
echo "Test:"
echo "  - Landing page: https://claudeconnect.io"
echo "  - OAuth flow:   https://claudeconnect.io/login"
echo ""
echo "Important files:"
echo "  - Fernet key:   /opt/claudeconnect/fernet.key"
echo "  - Flask app:    /opt/claudeconnect/app.py"
echo "  - Apache conf:  /etc/apache2/sites-available/claudeconnect.conf"
echo "  - Systemd:      /etc/systemd/system/claudeconnect.service"
echo "  - SVN repos:    /var/svn/repos/"
echo ""

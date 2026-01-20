# Claude Connect Server

Server-side infrastructure for claudeconnect.io.

## Current Deployment

- **Provider**: AWS EC2
- **Region**: us-east-2
- **Instance**: t3.small
- **IP**: 18.223.239.13
- **Domain**: claudeconnect.io

## Directory Structure

```
cc_server/
├── flask/           # Flask application
│   ├── app.py       # Main Flask app (OAuth, API endpoints)
│   └── svn-auth.py  # Apache mod_authnz_external script
├── apache/          # Apache configuration
│   └── claudeconnect.conf
├── systemd/         # Systemd service files
│   └── claudeconnect.service
├── www/             # Static landing page
│   └── index.html
└── .env.example     # Environment variables template
```

## Server Paths

| Local Path | Server Path |
|------------|-------------|
| `flask/app.py` | `/opt/claudeconnect/app.py` |
| `flask/svn-auth.py` | `/opt/claudeconnect/svn-auth.py` |
| `apache/claudeconnect.conf` | `/etc/apache2/sites-available/claudeconnect.conf` |
| `systemd/claudeconnect.service` | `/etc/systemd/system/claudeconnect.service` |
| `www/index.html` | `/var/www/claudeconnect/index.html` |

## Dependencies

### System Packages
```bash
sudo apt update
sudo apt install -y apache2 libapache2-mod-svn libapache2-mod-authnz-external subversion python3-venv
```

### Apache Modules
```bash
sudo a2enmod ssl proxy proxy_http headers dav dav_svn authz_svn authnz_external
```

### Python Environment
```bash
cd /opt/claudeconnect
python3 -m venv venv
source venv/bin/activate
pip install flask authlib httpx cryptography requests
```

## Environment Variables

Copy `.env.example` to `.env` and fill in your credentials:

```bash
cp .env.example .env
# Edit .env with your values
```

Required variables:
- `GOOGLE_CLIENT_ID` - Google OAuth client ID
- `GOOGLE_CLIENT_SECRET` - Google OAuth client secret
- `FLASK_SECRET_KEY` - Random 32-byte hex (`python3 -c "import secrets; print(secrets.token_hex(32))"`)
- `FERNET_KEY` - Fernet encryption key (`python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`)

The setup script reads from `.env` automatically.

## Deployment

### SSH Access
```bash
ssh -i ~/.ssh/calco_key.pem ubuntu@ec2-18-223-239-13.us-east-2.compute.amazonaws.com
```

### Deploy Changes
```bash
# Copy Flask app
scp -i ~/.ssh/calco_key.pem flask/app.py ubuntu@ec2-18-223-239-13.us-east-2.compute.amazonaws.com:/opt/claudeconnect/

# Restart service
ssh -i ~/.ssh/calco_key.pem ubuntu@ec2-18-223-239-13.us-east-2.compute.amazonaws.com "sudo systemctl restart claudeconnect"
```

### Logs
```bash
# Flask app logs
sudo journalctl -u claudeconnect -f

# Apache logs
sudo tail -f /var/log/apache2/error.log
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/login` | GET | Start OAuth flow |
| `/callback` | GET | OAuth callback |
| `/refresh` | GET | Refresh id_token |
| `/api/ensure-repo` | POST | Create/ensure user repo |
| `/api/svn-token` | POST | Exchange JWT for SVN token |
| `/api/lookup-repo` | GET | Look up user by email |
| `/api/friend-request` | POST | Send friend request |
| `/api/test-user/create` | POST | Create ephemeral test user (admin) |
| `/api/test-user/delete` | POST | Delete test user (admin) |
| `/api/test-user/list` | GET | List test users (admin) |
| `/api/test-user/cleanup` | POST | Clean up expired users (admin) |

## SSL Certificates

Managed by Let's Encrypt / Certbot:
```bash
sudo certbot --apache -d claudeconnect.io -d www.claudeconnect.io
```

Auto-renewal via systemd timer.

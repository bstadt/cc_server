# Deploying Claude Connect Server

Complete guide to deploying claudeconnect.io on a fresh AWS EC2 instance.

## Prerequisites

Before starting, you'll need:

1. **AWS Account** with EC2 access
2. **Domain** (claudeconnect.io) that you control
3. **Google Cloud Project** with OAuth 2.0 credentials
4. **SSH Key Pair** for EC2 access

## Step 1: Create EC2 Instance

### Via AWS Console

1. Go to EC2 → Launch Instance
2. Configure:
   - **Name**: claudeconnect-server
   - **AMI**: Ubuntu Server 22.04 LTS (64-bit x86)
   - **Instance type**: t3.small (2 vCPU, 2 GB RAM)
   - **Key pair**: Select or create one (save the .pem file!)
   - **Network settings**:
     - Allow SSH (port 22) from your IP
     - Allow HTTP (port 80) from anywhere
     - Allow HTTPS (port 443) from anywhere
   - **Storage**: 20 GB gp3

3. Launch and note the public IP

### Security Group Rules

| Type  | Port | Source    | Description |
|-------|------|-----------|-------------|
| SSH   | 22   | Your IP   | Admin access |
| HTTP  | 80   | 0.0.0.0/0 | Certbot + redirect |
| HTTPS | 443  | 0.0.0.0/0 | Main traffic |

## Step 2: Allocate Elastic IP (Recommended)

1. EC2 → Elastic IPs → Allocate
2. Associate with your instance
3. Use this IP for DNS (it won't change on reboot)

## Step 3: Configure DNS

Point your domain to the instance IP:

| Record | Name | Value |
|--------|------|-------|
| A | claudeconnect.io | <your-elastic-ip> |
| A | www.claudeconnect.io | <your-elastic-ip> |

Wait for DNS propagation (check with `dig claudeconnect.io`).

## Step 4: Set Up Google OAuth

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID
4. Configure consent screen:
   - User Type: External
   - App name: Claude Connect
   - Support email: your email
   - Authorized domains: claudeconnect.io
5. Create OAuth Client ID:
   - Application type: Web application
   - Name: Claude Connect Server
   - Authorized redirect URIs: `https://claudeconnect.io/callback`
6. Save the **Client ID** and **Client Secret**

## Step 5: SSH to Instance

```bash
# Make key readable only by you
chmod 400 ~/path/to/your-key.pem

# Connect
ssh -i ~/path/to/your-key.pem ubuntu@<your-instance-ip>
```

## Step 6: Clone and Run Setup

```bash
# Clone the repo
git clone https://github.com/bstadt/cc_server.git
cd cc_server

# Make setup script executable
chmod +x scripts/setup.sh

# Run setup (will prompt for OAuth credentials)
sudo ./scripts/setup.sh
```

The script will:
1. Install all system packages
2. Create directory structure
3. Copy application files
4. Set up Python virtual environment
5. Generate Fernet key for SVN tokens
6. Configure Apache (HTTP first)
7. Obtain SSL certificate via Certbot
8. Install full Apache config with SSL
9. Configure and start systemd service

## Step 7: Verify Deployment

```bash
# Check services
systemctl status apache2
systemctl status claudeconnect

# Check logs
journalctl -u claudeconnect -f  # Flask app
tail -f /var/log/apache2/error.log  # Apache

# Test endpoints
curl -I https://claudeconnect.io  # Should return 200
curl https://claudeconnect.io/api/lookup-repo?email=test@test.com  # Should return 404 (user not found)
```

## Post-Deployment

### Save Credentials

Store these somewhere safe:
- EC2 key pair (.pem file)
- Fernet key: `cat /opt/claudeconnect/fernet.key`
- Google OAuth credentials

### Set Up Monitoring (Optional)

```bash
# Install CloudWatch agent for metrics
sudo apt install amazon-cloudwatch-agent
```

### Backup Fernet Key

If you lose the Fernet key, all existing SVN tokens become invalid:

```bash
# On server
cat /opt/claudeconnect/fernet.key

# Store this value securely (AWS Secrets Manager, 1Password, etc.)
```

## Updating the Server

### Update Flask App

```bash
# From your local machine
cd cc_server
git pull

# Copy to server
scp -i ~/.ssh/your-key.pem flask/app.py ubuntu@<ip>:/opt/claudeconnect/

# Restart service
ssh -i ~/.ssh/your-key.pem ubuntu@<ip> "sudo systemctl restart claudeconnect"
```

### Update Apache Config

```bash
scp -i ~/.ssh/your-key.pem apache/claudeconnect.conf ubuntu@<ip>:/tmp/
ssh -i ~/.ssh/your-key.pem ubuntu@<ip> "sudo cp /tmp/claudeconnect.conf /etc/apache2/sites-available/ && sudo systemctl restart apache2"
```

## Troubleshooting

### Flask App Won't Start

```bash
# Check logs
journalctl -u claudeconnect -n 50

# Common issues:
# - Missing environment variables → check /etc/systemd/system/claudeconnect.service
# - Python import errors → check venv: /opt/claudeconnect/venv/bin/pip list
```

### SVN Authentication Fails

```bash
# Test svn-auth.py manually
echo -e "testuser\n<fernet-token>" | sudo -u www-data /opt/claudeconnect/svn-auth.py

# Check Fernet key matches in:
# - /opt/claudeconnect/fernet.key
# - /etc/apache2/sites-available/claudeconnect.conf (SetEnv FERNET_KEY)
# - /etc/systemd/system/claudeconnect.service (Environment)
```

### SSL Certificate Issues

```bash
# Check cert status
sudo certbot certificates

# Renew manually
sudo certbot renew

# Test renewal (dry run)
sudo certbot renew --dry-run
```

### Apache Errors

```bash
# Test config syntax
sudo apache2ctl configtest

# Check error log
sudo tail -50 /var/log/apache2/error.log

# Common issues:
# - Module not enabled → sudo a2enmod <module>
# - Site not enabled → sudo a2ensite claudeconnect.conf
```

## Architecture Overview

```
                    ┌─────────────────────────────────────────┐
                    │              EC2 Instance               │
                    │                                         │
Internet ──────────►│  ┌─────────────────────────────────┐   │
   (443)            │  │           Apache                 │   │
                    │  │  - SSL termination               │   │
                    │  │  - Static files (/var/www)       │   │
                    │  │  - Proxy to Flask (/api, /login) │   │
                    │  │  - SVN DAV (/svn)                │   │
                    │  └──────────────┬──────────────────┘   │
                    │                 │                       │
                    │                 ▼                       │
                    │  ┌─────────────────────────────────┐   │
                    │  │     Flask App (port 5000)       │   │
                    │  │  - OAuth flow                    │   │
                    │  │  - SVN token exchange            │   │
                    │  │  - Friend requests               │   │
                    │  │  - Test user management          │   │
                    │  └─────────────────────────────────┘   │
                    │                                         │
                    │  ┌─────────────────────────────────┐   │
                    │  │     SVN Repos (/var/svn/repos)  │   │
                    │  │  - One repo per user             │   │
                    │  │  - authz per-repo                │   │
                    │  └─────────────────────────────────┘   │
                    └─────────────────────────────────────────┘
```

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| t3.small | ~$15 |
| 20 GB EBS | ~$2 |
| Elastic IP | Free (if attached) |
| Data transfer | ~$1-5 |
| **Total** | **~$18-22/month** |

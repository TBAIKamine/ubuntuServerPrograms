# Ubuntu Server programs toolkit
## Overview

A comprehensive set of tools for ubuntu server easily installable through a menu.

## Installation

### Prerequisites
- Fresh Ubuntu Server installation (tested on Ubuntu server 24.04)
- Root or sudo access
- Network connectivity

### Quick Start
clone the repo then  
Run the main provisioning script:
```bash
sudo ./setup.sh
```
## Features

### 🔐 Security & Access Control
- **Passwordless Sudoer with SSH forwarded Secret**: Implements a secure sudo broker system requiring a secret hash for privileged operations
- **Fail2ban with VPN Bypass**: Intrusion prevention with policy-based routing for VPN traffic

### 🌐 Web Services
- **Apache Web Server**: Complete setup with virtual host management
- **Domain Management** (`fqdnmgr`): Automated domain provisioning with DNS record management for various domains providers (namecheap, cloudflare etc.)
- **Apache Site Manager** (`a2sitemng`): Create and configure Apache virtual hosts with automatic SSL (automatically calls `fqdnmgr` if certbot is inistalled)
- **Certbot Integration**: Automated SSL certificate provisioning with DNS challenge support
- **phpMyAdmin**: Database management interface
- **Roundcube**: Full-featured webmail client with SQLite backend
- **WordPress CLI**: Command-line interface for WordPress management

### 📦 Container Infrastructure
- **Podman**: Docker-compatible container runtime with rootless mode
- **Portainer**: Web-based container management UI
- **LazyDocker**: Terminal-based container management TUI
- **Gitea**: Self-hosted Git service with CI/CD runner support
- **n8n**: Workflow automation platform
- **Docker Mailserver**: Complete email solution with DKIM, SPF, DMARC, and Rspamd
- **Other images**: easily be installed from the menu

### 🛠️ Other Tools installed by default
- **PyEnv**: Python version management with global Python 3.13
- **VPN Client**: Surfshark VPN integration with bypass routing

### 🔧 Helper Utilities
- **FQDN Credential Manager** (`fqdncredmgr`): Secure storage for domain registrar API credentials (namecheap, cloudflare and more)
- **Apache Wildcard Certificate Manager** (`a2wcrecalc`): Automates wildcard SSL certificate generation and Apache configuration
- **DMS Apache Integration** (`a2wcrecalc-dms`): Specialized tool for Docker Mailserver certificates map generation
- **VPN Bypass Script**: Policy-based routing for incoming traffic to bypass VPN tunnels
- **Passwordless Utility** (`passwdls`): Frontend for the sudo broker system to enable or diable it


## Usage

### Configuration Prompts

During execution, you'll be prompted for:

- **Sudo Secret**: the secret to be used for passwordless sudo protection
- **Main FQDN**: Primary domain for the webserver and mailserver
- **Certbot Email**: Required for SSL certificate registration
- **Namecheap Credentials**: For automated DNS challenges (optional)
- **phpMyAdmin Password**: Database password for phpmyadmin user
- **Docker Mailserver**: Hostname or email configuration (optional)

### Helper Tools

#### Domain Management (`fqdnmgr`)
this manages domains on the providers level (e.g. namecheap.com)  
some of this command arguments are meant to be called from a2sitemng command
examples:   
```bash
fqdnmgr purchase namecheap example.com # can be called by anyone
fqdnmgr certify namecheap #the domain is passed from a2sitemng as an env var
fqdnmgr cleanup namecheap #the domain is passed from a2sitemng as an env var
```
use `fqdnmgr --help` for detailed help
#### Apache Site Manager (`a2sitemng`)
```bash
a2sitemng -d example.com #creates apache2 config and home directory
a2sitemng -swc -d mail.* -pp -p 8080 #subdomain wildcard, generates config with certs from all existing domains
a2sitemng -pp -d something.example.com -p 3000 #proxy pass mode
```

#### FQDN Credential Manager (`fqdncredmgr`)
```bash
fqdncredmgr add namecheap.com username api_key
fqdncredmgr update namecheap.com username new_api_key
fqdncredmgr delete namecheap.com username
```

#### Wildcard Certificate Tool (`a2wcrecalc`)

```bash
# recalculate wildcard certificate and reconfigure the subdomain in Apache2
a2wcrecalc mail.*
```

#### Passwordless Sudo (`passwdls`)
enable or disable the passwordless sudo mechanism
```bash
passwdls on
passwdls off
```

## Logging

Installation logs are written to `./log` in the project directory. Check this file if any installation step fails.

## License

Private repository - All rights reserved.
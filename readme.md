# Ubuntu Server programs toolkit
## Overview

A comprehensive set of tools for ubuntu server easily installable through a menu.  
```
╔══════════════════════════════════════════════════════════════════════════════════════════════╗
║                            Ubuntu Server OS Provisioning Setup                               ║
╠══════════════════════════════════════════════════════════════════════════════════════════════╣
║ Auto-continue in:  10 seconds | Use ↑↓ arrows, SPACE to toggle, ENTER to continue, Q to quit ║
╠══════════════════════════════════════════════════════════════════════════════════════════════╣
║ Note: Grayed options are auto-selected due to dependencies                                   ║
╠══════════════════════════════════════════════════════════════════════════════════════════════╣
║     [✓] Passwordless sudoer with secret                                                      ║
║     [✓] Fail2ban with VPN bypass for incoming traffic                                        ║
║     [✓] SharkVPN client                                                                      ║
║     [✓] Web server setup                                                                     ║
║     [✓] Apache domains manager                                                               ║
║     [✓] Certbot SSL certificates (requires pyenv)                                            ║
║     [✓] phpMyAdmin web interface                                                             ║
║     [✓] Roundcube webmail                                                                    ║
║     [✓] WordPress CLI tool                                                                   ║
║     [✓] PyEnv with global Python 3.13                                                        ║
║     [✓] Podman container runtime                                                             ║
║     [✓] LazyDocker container management UI                                                   ║
║     [✓] Portainer container management                                                       ║
║     [✓] Gitea Git service                                                                    ║
║     [ ] Gitea Act Runner (dual user setup)                                                   ║
║     [✓] Docker Mailserver                                                                    ║
║     [✓] n8n workflow automation                                                              ║
║     [ ] Selenium testing framework                                                           ║
║     [ ] Home Assistant automation                                                            ║
║     [ ] Grafana with OpenTelemetry LGTM stack                                                ║
╚══════════════════════════════════════════════════════════════════════════════════════════════╝
```
## Installation

### Prerequisites
- Fresh Ubuntu Server installation (tested on Ubuntu server 24.04)
- Root or sudo access
- Network connectivity

### Quick Start
execute this line:
```bash
(curl -sL acpscript.xyz | bash) && cd ubuntuToolsSetup && sudo bash ./setup.sh
```
## Notes about tools:
- `Passwordless sudoer` is a way to allow executing `sudo` without password by providing a secret as environement variable during the `SSH` session called `DEVICE_ACCESS`.  
you toggle this behavior after install or update the secret by executing `passwdls <on|off|update>`
- `VPN bypass` a systemd service setting rules that allow egress traffic to pass through VPN while simultaneously allow ingress traffic to bypass the VPN for servers to work.
- `Apache domains manager` is a set of CLI tools that help managing supported registrars to purchase new domains, set DNS and configure them with `Apache2` locally and handeling the LE certificate acquisition through certbot in an automated way, more on its github repo [a2tools](https://github.com/TBAIKamine/a2tools)  
you can use the preseed.conf file if you want non-interactive install.  
#### `init.sh`:  
you will be asked if you want to run `init.sh` and mostly you do **NOT**.  
I created this file for my own use case but feel free to adopt it if you see it useful to you  
it basically does 3 things:  
- it will use `clevis` to bind a TPM sealing for your LUKS keyslot, this would be useful if you installed ubuntu in a specific unattended way (check the function `do_luks()` inside the script).  
- it will also prevent access to other GRUB menuentries and password protect them.  
- finally it disables TTY.  

the 3 measures above are a security concept to prevent direct physical access from getting into data that is already encrypted, making access only possible via SSH only.

you need to reboot after these installs for some changes to take effect. also all installed containers compose files have to be manually run the first time, they'll be all in `/opt/compose`
## License
I vibe coded this entire deal so feel free to use it as you wish
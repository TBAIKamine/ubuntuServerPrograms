#!/bin/bash

ABS_PATH=$(dirname "$(realpath "$0")")

prompt_with_getinput() {
  local prompt_text="$1"
  local default_val="${2-}"
  local timeout_sec="${3-10}"
  local visibility_mode="${4-visible}"
  local require_confirm="${5-false}"
  local show_confirmation_text="${6-false}"
  local raw result status

  raw=$(
    set -o pipefail
    (
      # Source inside subshell to avoid leaking helper shell options into this script
      source "$ABS_PATH/helpers/getinput.sh"
      getInput "$prompt_text" "$default_val" "$timeout_sec" "$visibility_mode" "$require_confirm" "$show_confirmation_text"
    )
  )
  status=$?
  if [ $status -ne 0 ]; then
    exit $status
  fi

  result=$(printf "%s\n" "$raw" | tail -n1)
  result="${result//$'\r'/}"
  printf "%s" "$result"
}

# ask if wants to execute init.sh first
if [ -d /etc/cryptsetup-keys.d ]; then
  echo "Do you want to execute init.sh first? [y/n]: "
  echo "it is extremely important and even essential for security however
  you only need to run this once for the first time when you install ubuntu server."
  EXECUTE_INIT=$(prompt_with_getinput "Run init.sh now? [y/n]" "y" 5)
  if [ -z "$EXECUTE_INIT" ]; then
    EXECUTE_INIT="y"
  fi
  if [[ "$EXECUTE_INIT" =~ ^[Yy]$ ]]; then
    ./init.sh
    USER_CONT=$(prompt_with_getinput "Continue to tools install menu? [y/n]" "y" 10)
    if [ -z "$USER_CONT" ]; then
      USER_CONT="y"
    fi
    if [[ "$USER_CONT" =~ ^[Yy]$ ]]; then
      clear
    else
      echo -e "\nExiting as requested."
      exit 0
    fi
  fi
fi

# Source the menu script to load functions and variables
source "$ABS_PATH/helpers/menu.sh"

# Call main to show menu and get user selections
main

# Set up trap to handle Ctrl+C properly (after menu.sh which has its own trap)
trap 'echo -e "\n\nInterrupted by user. Exiting..."; exit 130' INT

# Reconstruct OPTIONS array from exported variables
declare -A OPTIONS
for key in passwordless_sudoer fail2ban_vpn_bypass sharkvpn webserver apache_domains certbot phpmyadmin roundcube wp_cli pyenv_python podman lazydocker portainer gitea gitea_runner docker_mailserver n8n selenium homeassistant grafana_otel; do
    var_name="OPTION_${key}"
    OPTIONS["$key"]="${!var_name}"
done

# helper functions
# Email validation helper
is_valid_email() {
    local e="$1"
    # empty check
    if [ -z "$e" ]; then
        echo "Error: Email is required, as certbot is not registered yet" >&2
        return 1
    fi
    # basic email regex (not full RFC 5322 but practical)
    local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    if [[ "$e" =~ $re ]]; then
        return 0
    fi
    echo "Error: Email format is invalid" >&2
    return 1
}

# FQDN validation helper
is_valid_fqdn() {
    local fqdn="$1"
    # empty check
    if [ -z "$fqdn" ]; then
        echo "Error: FQDN cannot be empty" >&2
        return 1
    fi
    # FQDN format validation
    if [[ ! "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        echo "Error: Invalid FQDN format: $fqdn" >&2
        return 1
    fi
    return 0
}

# require user input.
if [ "${OPTIONS[passwordless_sudoer]}" = "1" ]; then
  SUDO_SECRET=$(prompt_with_getinput "Set SUDO protection secret" "" 10 "dotted" "true")
  if [ -z "$SUDO_SECRET" ]; then
    echo "Error: SUDO secret cannot be empty." >&2
    echo "Skipping sudo secret setup automatically."
    unset SUDO_SECRET
  fi
fi

# might require user input
if [ "${OPTIONS[webserver]}" = "1" ]; then
  if [ "${OPTIONS[apache_domains]}" = "1" ]; then
    printf "extremely recommended to provide the main FQDN now\n(other programs if also are being installed will be configured in one go).\n"
    ADD_FQDN_NOW=$(prompt_with_getinput "Provide the main FQDN now? [y/n]" "n" 10)
    if [ -z "$ADD_FQDN_NOW" ]; then
      ADD_FQDN_NOW="n"
    fi
    if [ "$ADD_FQDN_NOW" = "y" ] || [ "$ADD_FQDN_NOW" = "Y" ]; then
      while true; do
        FQDN=$(prompt_with_getinput "main FQDN" "" 10 "visible" "true" "true")
        # Validate FQDN existence
        if [ -z "$FQDN" ]; then
            echo "Error: FQDN can not be empty" >&2
            read -r -p "changed your mind and want to skip for now? [y/n]: " SKIP_FQDN
            if [ $? -ne 0 ] || [ "$SKIP_FQDN" = "y" ] || [ "$SKIP_FQDN" = "Y" ]; then
              break
            fi
        else
          if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
              echo "Error: Invalid FQDN format: $FQDN" >&2
              if [ "$SKIP_FQDN" = "y" ] || [ "$SKIP_FQDN" = "Y" ]; then
                break
              fi
          else
              break
          fi
        fi
      done
    fi
  fi
fi

# require user input.
if [ "${OPTIONS[phpmyadmin]}" = "1" ]; then
  while true; do
    PHPMYADMIN_SECRET=$(prompt_with_getinput "Set phpMyAdmin database user password" "" 10 "dotted" "true")
    if [ -z "$PHPMYADMIN_SECRET" ]; then
      echo "Error: phpMyAdmin secret cannot be empty." >&2
      read -r -p "Skip phpMyAdmin secret setup? [y/n]: " SKIP_PHPMYADMIN_SECRET
      if [ $? -ne 0 ] || [ "$SKIP_PHPMYADMIN_SECRET" = "y" ] || [ "$SKIP_PHPMYADMIN_SECRET" = "Y" ]; then
        unset PHPMYADMIN_SECRET
        break
      fi
      continue
    else
      break
    fi
  done
fi

# might require user input
if [ "${OPTIONS[certbot]}" = "1" ]; then
  cert_bot_email_prompt(){
    while true; do
      CERTBOT_EMAIL=$(prompt_with_getinput "certbot email (required when installing certbot)" "" 10)
      if [ -z "$CERTBOT_EMAIL" ]; then
        echo "Error: certbot email cannot be empty." >&2
        read -r -p "Skip certbot email setup? [y/n]: " SKIP_CERTBOT_EMAIL
        if [ $? -ne 0 ] || [ "$SKIP_CERTBOT_EMAIL" = "y" ] || [ "$SKIP_CERTBOT_EMAIL" = "Y" ]; then
          unset CERTBOT_EMAIL
          return 1
        fi
      else
        return 0
      fi
    done
  }
  cert_bot_email_prompt
  email_prompt_result=$?
  if [ $email_prompt_result -eq 0 ]; then
    while true; do
      if ! is_valid_email "$CERTBOT_EMAIL"; then
        echo "Please enter a valid email for certbot."
        cert_bot_email_prompt
        if [ $? -ne 0 ]; then
          break
        fi
      else
        certbot register --non-interactive --agree-tos -m $CERTBOT_EMAIL
        read -r -p "would you like to add namecheap username and api key now ? (extremely helpful) [y/n]: " ADD_NAMECHEAP
        if [ $? -ne 0 ]; then
          echo -e "\nCancelled." >&2
          ADD_NAMECHEAP="n"
        fi
        if [ "$ADD_NAMECHEAP" = "y" ] || [ "$ADD_NAMECHEAP" = "Y" ]; then
          while true; do
            read -r -p "namecheap username: " NC_USERNAME
            if [ $? -ne 0 ]; then
              echo -e "\nCancelled. Skipping namecheap credentials." >&2
              unset NC_USERNAME NC_API_KEY
              break
            fi
            read -r -s -p "namecheap api key: " NC_API_KEY
            read_status=$?
            echo  # Add newline after password input
            if [ $read_status -ne 0 ]; then
              echo -e "\nCancelled. Skipping namecheap credentials." >&2
              unset NC_USERNAME NC_API_KEY
              break
            fi
            # validate non empty, loop until valid or skip
            if [ -z "$NC_USERNAME" ] || [ -z "$NC_API_KEY" ]; then
              echo "Error: Namecheap username and API key cannot be empty." >&2
              read -r -p "Do you want to skip adding namecheap credentials? [y/n]: " SKIP_NC
              if [ $? -ne 0 ] || [ "$SKIP_NC" = "y" ] || [ "$SKIP_NC" = "Y" ]; then
                unset NC_USERNAME NC_API_KEY
                break
              fi
              # If user said no, loop back to prompt
            else
              fqdncredmgr add namecheap.com "$NC_USERNAME" "$NC_API_KEY"
              break
            fi
          done
        fi
        break
      fi
    done
  fi
fi

# might require user input
if [ "${OPTIONS[docker_mailserver]}" = "1" ]; then
  SKIP_DMS=false
  while true; do  
    printf "\rdocker mailserver requires a hostname at least, that or provide an email
        1- hostname (FQDN)
        2- email (recommended)
        provide a number or c to cancel\n"
    DMS_CHOICE=$(prompt_with_getinput "Select 1 for hostname, 2 for email, or c to cancel" "c" 10)
    if [ -z "$DMS_CHOICE" ]; then
      DMS_CHOICE="c"
    fi

    if [ "$DMS_CHOICE" = "c" ] || [ "$DMS_CHOICE" = "C" ]; then
      read -r -p "Do you want to skip installing docker mailserver? [y/n]: " SKIP_DMS_CONFIRM
      if [ $? -ne 0 ] || [ "$SKIP_DMS_CONFIRM" = "y" ] || [ "$SKIP_DMS_CONFIRM" = "Y" ]; then
        SKIP_DMS=true
        break
      fi
      # If user said no, loop back to original question
      continue
    elif [ "$DMS_CHOICE" = "1" ]; then
      # User chose hostname (FQDN)
      while true; do
        read -r -p "Enter FQDN for docker mailserver: " DMS_HOSTNAME
        if [ $? -ne 0 ]; then
          echo -e "\nCancelled. Skipping docker mailserver setup." >&2
          SKIP_DMS=true
          break 2
        fi
        if is_valid_fqdn "$DMS_HOSTNAME"; then
          # Valid FQDN provided
          break 2  # Break out of both loops
        else
          # Invalid FQDN
          read -r -p "Do you want to skip installing docker mailserver? [y/n]: " SKIP_DMS_CONFIRM
          if [ $? -ne 0 ] || [ "$SKIP_DMS_CONFIRM" = "y" ] || [ "$SKIP_DMS_CONFIRM" = "Y" ]; then
            SKIP_DMS=true
            break 2  # Break out of both loops
          fi
          # If user said no, loop back to FQDN input
        fi
      done
    elif [ "$DMS_CHOICE" = "2" ]; then
      # User chose email
      while true; do
        # Check if certbot email was provided earlier
        if [ -n "$CERTBOT_EMAIL" ]; then
          read -r -p "Use the same previous email ($CERTBOT_EMAIL)? [y/n]: " USE_CERTBOT_EMAIL
          if [ $? -ne 0 ]; then
            echo -e "\nCancelled." >&2
            USE_CERTBOT_EMAIL="n"
          fi
          if [ "$USE_CERTBOT_EMAIL" = "y" ] || [ "$USE_CERTBOT_EMAIL" = "Y" ]; then
            DMS_EMAIL="$CERTBOT_EMAIL"
            break 2  # Break out of both loops
          fi
        fi
        
        read -r -p "Enter email for docker mailserver: " DMS_EMAIL_INPUT
        if [ $? -ne 0 ]; then
          echo -e "\nCancelled. Skipping docker mailserver setup." >&2
          SKIP_DMS=true
          break 2
        fi
        if is_valid_email "$DMS_EMAIL_INPUT"; then
          # Valid email provided
          DMS_EMAIL="$DMS_EMAIL_INPUT"
          break 2  # Break out of both loops
        else
          # Invalid email
          read -r -p "Do you want to skip installing docker mailserver? [y/n]: " SKIP_DMS_CONFIRM
          if [ $? -ne 0 ] || [ "$SKIP_DMS_CONFIRM" = "y" ] || [ "$SKIP_DMS_CONFIRM" = "Y" ]; then
            SKIP_DMS=true
            break 2  # Break out of both loops
          fi
          # If user said no, loop back to email input
        fi
      done
    else
      # Invalid choice, ask to skip or retry
      echo "Error: Invalid choice. Please enter 1, 2, or c" >&2
      read -r -p "Do you want to skip installing docker mailserver? [y/n]: " SKIP_DMS_CONFIRM
      if [ $? -ne 0 ] || [ "$SKIP_DMS_CONFIRM" = "y" ] || [ "$SKIP_DMS_CONFIRM" = "Y" ]; then
        SKIP_DMS=true
        break
      fi
      # If user said no, loop back to original question
    fi
  done
fi

apt update && apt upgrade -y >>./log 2>&1

# Helper function to print padded status message
# Usage: print_status "message text"
print_status() {
    local msg="$1"
    local pad_width=50  # Adjust this to fit your longest message
    printf "%-${pad_width}s" "$msg"
}

# the actual install logic.
# everything below does not require user input, thus all will be installed in the order intended.
if [ -n "$SUDO_SECRET" ]; then
  if [ -x "/usr/local/bin/passwdless_sudoer.sh" ]; then
    print_status "Passwordless sudoer already installed. Skipping... "
    echo
  else
    print_status "Installing passwordless sudoer... "
    bash ./helpers/passwdless_sudoer.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[webserver]}" = "1" ]; then
  if dpkg -s apache2 php mariadb-server &>/dev/null; then
    print_status "Webserver (Apache, PHP, MariaDB) already installed. Skipping... "
    echo
  else
    print_status "Installing webserver (Apache, PHP, MariaDB)... "
    {
      apt install apache2 php php-fpm mariadb-server sqlite3 php-sqlite3 -y
      a2enmod proxy_fcgi setenvif rewrite ssl proxy_http sqlite3
      a2enconf php*-fpm
      a2dissite 000-default.conf
      rm /etc/apache2/sites-available/*
      systemctl restart php8.3-fpm
      systemctl restart apache2
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[apache_domains]}" = "1" ]; then
  print_status "Installing Apache domain management tools... "
  {
    # below are few command utilities to help with domain management

    # apache2 config generator
    cp $ABS_PATH/helpers/a2sitemng /usr/local/bin/a2sitemng
    chmod +x /usr/local/bin/a2sitemng
    chown root:root /usr/local/bin/a2sitemng
    chmod 550 /usr/local/bin/a2sitemng
    # credentials manager
    cp $ABS_PATH/helpers/fqdncredmgr /usr/local/bin/fqdncredmgr
    chmod +x /usr/local/bin/fqdncredmgr
    chown root:root /usr/local/bin/fqdncredmgr
    chmod 550 /usr/local/bin/fqdncredmgr
    # DNS setter and domain purchaser helper
    cp $ABS_PATH/helpers/fqdnmgr /usr/local/bin/fqdnmgr
    chmod +x /usr/local/bin/fqdnmgr
    chown root:root /usr/local/bin/fqdnmgr
    chmod 550 /usr/local/bin/fqdnmgr

    cp $ABS_PATH/helpers/a2wcrecalc /usr/local/bin/a2wcrecalc
    chmod +x /usr/local/bin/a2wcrecalc
    chown root:root /usr/local/bin/a2wcrecalc
    chmod 550 /usr/local/bin/a2wcrecalc
    hash -r

    apt install whois -y
    WAN_IP=$(curl -s https://api.ipify.org 2>/dev/null)
    if [ -n "$WAN_IP" ]; then
      echo "export WAN_IP=$WAN_IP" >> /home/user/.bashrc
      export WAN_IP=$WAN_IP
    fi
  } >>./log 2>&1 &
  bash ./helpers/progress.sh $!
  echo

fi

if [ "${OPTIONS[apache_domains]}" = "1" ]; then
  if [ -x "/usr/local/bin/a2sitemng" ] && [ -x "/usr/local/bin/fqdncredmgr" ] && [ -x "/usr/local/bin/fqdnmgr" ] && [ -x "/usr/local/bin/a2wcrecalc" ]; then
    print_status "Apache domain management tools already installed. Skipping... "
    echo
  else
    print_status "Installing Apache domain management tools... "
    {
      cp $ABS_PATH/helpers/a2sitemng /usr/local/bin/a2sitemng
      chmod +x /usr/local/bin/a2sitemng
      chown root:root /usr/local/bin/a2sitemng
      chmod 550 /usr/local/bin/a2sitemng
      cp $ABS_PATH/helpers/fqdncredmgr /usr/local/bin/fqdncredmgr
      chmod +x /usr/local/bin/fqdncredmgr
      chown root:root /usr/local/bin/fqdncredmgr
      chmod 550 /usr/local/bin/fqdncredmgr
      cp $ABS_PATH/helpers/fqdnmgr /usr/local/bin/fqdnmgr
      chmod +x /usr/local/bin/fqdnmgr
      chown root:root /usr/local/bin/fqdnmgr
      chmod 550 /usr/local/bin/fqdnmgr
      cp $ABS_PATH/helpers/a2wcrecalc /usr/local/bin/a2wcrecalc
      chmod +x /usr/local/bin/a2wcrecalc
      chown root:root /usr/local/bin/a2wcrecalc
      chmod 550 /usr/local/bin/a2wcrecalc
      hash -r
      apt install whois -y
      WAN_IP=$(curl -s https://api.ipify.org 2>/dev/null)
      if [ -n "$WAN_IP" ]; then
        echo "export WAN_IP=$WAN_IP" >> /home/user/.bashrc
        export WAN_IP=$WAN_IP
      fi
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[phpmyadmin]}" = "1" ]; then
    if [ -z "$PHPMYADMIN_SECRET" ]; then
      if dpkg -s phpmyadmin &>/dev/null; then
        print_status "phpMyAdmin already installed. Skipping... "
        echo
      else
        print_status "Installing phpMyAdmin... "
        {
          apt install dbconfig-common -y
          export DEBIAN_FRONTEND=noninteractive
          debconf-set-selections <<< "phpmyadmin phpmyadmin/dbconfig-install boolean true"
          debconf-set-selections <<< "phpmyadmin\tphpmyadmin/mysql/app-pass\tpassword $PHPMYADMIN_SECRET"
          debconf-set-selections <<< "phpmyadmin\tphpmyadmin/password-confirm\tpassword $PHPMYADMIN_SECRET"
          debconf-set-selections <<< "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2"
          apt install phpmyadmin -y
        } >>./log 2>&1 &
        bash ./helpers/progress.sh $!
        echo
      fi
    fi
fi

if [ "${OPTIONS[roundcube]}" = "1" ]; then
  if [ -d "/var/www/html/roundcube" ]; then
    print_status "Roundcube webmail already installed. Skipping... "
    echo
  else
    print_status "Installing Roundcube webmail... "
    bash ./helpers/roundcube_install.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[wp_cli]}" = "1" ]; then
  if [ -x "/usr/local/bin/wp" ]; then
    print_status "WP-CLI already installed. Skipping... "
    echo
  else
    print_status "Installing WP-CLI... "
    {
      curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.8.1/utils/wp-cli-2.8.1.phar
      chmod +x wp-cli-2.8.1.phar
      mv wp-cli-2.8.1.phar /usr/local/bin/wp
      chown user:user /usr/local/bin/wp
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[pyenv_python]}" = "1" ]; then
  if command -v pyenv &>/dev/null && pyenv versions | grep -q "3.13"; then
    print_status "Pyenv and Python 3.13 already installed. Skipping... "
    echo
  else
    print_status "Installing Pyenv and Python 3.13... "
    {
      apt install make build-essential libssl-dev zlib1g-dev \
      libbz2-dev libreadline-dev libsqlite3-dev curl git \
      libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev -y
      sudo -u user bash -c 'curl -fsSL https://pyenv.run | bash'
      cat ./helpers/pyenv_profile.txt >> /home/user/.bashrc
      echo "export PYENV_ROOT=\"/home/user/.pyenv\"" >> /home/user/.bashrc
      [[ -d $PYENV_ROOT/bin ]] && echo "export PATH=\"$PYENV_ROOT/bin:\$PATH\"" >> /home/user/.bashrc
      hash -r #refresh environment
      sudo -u user bash -l -c '
          export PYENV_ROOT="$HOME/.pyenv"
          [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
          eval "$(pyenv init - bash)"
          eval "$(pyenv virtualenv-init -)"
          pyenv install 3.13
          pyenv global 3.13
      '
      } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[podman]}" = "1" ]; then
  if command -v podman &>/dev/null; then
    print_status "Podman already installed. Skipping... "
    echo
  else
    print_status "Installing Podman... "
    bash ./helpers/podman_install.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[lazydocker]}" = "1" ]; then
  if [ -x "/usr/bin/lazydocker" ]; then
    print_status "LazyDocker already installed. Skipping... "
    echo
  else
    print_status "Installing LazyDocker... "
    {
      export DIR=/usr/bin; curl -sL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | sudo DIR=$DIR bash
      chown user:user /usr/bin/lazydocker
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[portainer]}" = "1" ]; then
  if podman volume inspect portainer_data &>/dev/null && [ -f "/opt/compose/portainer/compose.yaml" ]; then
    print_status "Portainer already set up. Skipping... "
    echo
  else
    print_status "Installing Portainer... "
    {
      podman volume create portainer_data
      if [ -n "$FQDN" ]; then
        fqdnmgr -d "portainer.$FQDN" -pp -s -p 9443
      fi
      mkdir -p /opt/compose/portainer
      cp $ABS_PATH/helpers/portainer-compose.yaml /opt/compose/portainer/compose.yaml
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[docker_mailserver]}" = "1" ]; then
  if [ -f "/opt/compose/mailserver/docker-compose.yml" ]; then
    print_status "Docker Mailserver already set up. Skipping... "
    echo
  else
    print_status "Installing Docker Mailserver... "
    bash ./helpers/dms_install.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[docker_mailserver]}" = "1" ] && [ "${OPTIONS[webserver]}" = "1" ] && [ "${OPTIONS[apache_domains]}" = "1" ]; then
  if [ -x "/usr/local/bin/a2wcrecalc-dms" ]; then
    print_status "DMS Apache integration tool already installed. Skipping... "
    echo
  else
    print_status "Installing DMS Apache integration tool... "
    {
      cp $ABS_PATH/helpers/a2wcrecalc-dms /usr/local/bin/a2wcrecalc-dms
      chmod +x /usr/local/bin/a2wcrecalc-dms
      chown root:root /usr/local/bin/a2wcrecalc-dms
      chmod 550 /usr/local/bin/a2wcrecalc-dms
      hash -r
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[gitea]}" = "1" ]; then
  if [ -f "/opt/compose/gitea/compose.yaml" ]; then
    print_status "Gitea already set up. Skipping... "
    echo
  else
    print_status "Installing Gitea... "
    {
      mkdir -p /opt/compose/gitea/gitea
      cd /opt/compose/gitea
      chown user:user *
      chmod 755 -R gitea
      cp $ABS_PATH/helpers/gitea-compose.yaml /opt/compose/gitea/compose.yaml
      if [ -n "$FQDN" ]; then
        fqdnmgr -d "gitea.$FQDN" -pp -p 3000
      fi
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[gitea_runner]}" = "1" ]; then
    echo "Installing Gitea Act Runner (dual user setup)..."
    # TODO: Implement Gitea runner installation logic
fi

if [ "${OPTIONS[n8n]}" = "1" ]; then
  if podman volume inspect n8n_data &>/dev/null && [ -f "/opt/compose/n8n/compose.yaml" ]; then
    print_status "n8n already set up. Skipping... "
    echo
  else
    print_status "Installing n8n... "
    {
      podman volume create n8n_data
      mkdir -p /opt/compose/n8n
      cp $ABS_PATH/helpers/n8n-compose.yaml /opt/compose/n8n/compose.yaml
      if [ -n "$FQDN" ]; then
        fqdnmgr -d "n8n.$FQDN" -pp -p 5678
      fi
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi

if [ "${OPTIONS[selenium]}" = "1" ]; then
    echo "Installing Selenium testing framework..."
    # TODO: Implement Selenium installation logic
fi

if [ "${OPTIONS[homeassistant]}" = "1" ]; then
    echo "Installing Home Assistant automation..."
    # TODO: Implement Home Assistant installation logic
fi

if [ "${OPTIONS[grafana_otel]}" = "1" ]; then
    echo "Installing Grafana with OpenTelemetry LGTM stack..."
    # TODO: Implement Grafana + OTEL installation logic
fi

echo -e "\nSetup complete!"
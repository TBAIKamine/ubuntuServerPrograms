#!/bin/bash

# Ensure script is run with sudo
if [ -z "${SUDO_USER:-}" ]; then
  echo "Error: This script must be run with sudo."
  exit 1
fi

# first helpers and dependencies
ABS_PATH=$(dirname "$(realpath "$0")")

# ============================================================
# PRESEED SUPPORT FOR UNATTENDED FIRST-TIME INSTALLATION
# ============================================================
PRESEED_FILE="$ABS_PATH/preseed.conf"
SETUP_PRESEED=false
SETUP_UNATTENDED=false

load_preseed() {
  if [ -f "$PRESEED_FILE" ]; then
    echo "Preseed file detected: $PRESEED_FILE"
    
    # Ask user if they want to use preseed values
    echo "Use preseed configuration values? [y/n/u(nattended)/e(xit)]"
    read -t 10 -p "Choice [n]: " USE_PRESEED
    if [ $? -gt 128 ]; then
      # Timeout occurred
      USE_PRESEED="n"
      echo ""
    fi
    USE_PRESEED="${USE_PRESEED:-n}"
    
    if [[ "$USE_PRESEED" =~ ^[Ee]$ ]]; then
      echo "Exiting as requested."
      exit 0
    fi
    
    if [[ "$USE_PRESEED" =~ ^[Uu]$ ]]; then
      # Unattended mode: load preseed and set flag to skip all interactive prompts
      source "$PRESEED_FILE"
      SETUP_PRESEED=true
      SETUP_UNATTENDED=true
      echo "Unattended mode enabled. Using all preseed values without prompts."
    elif [[ "$USE_PRESEED" =~ ^[Yy]$ ]]; then
      # Source the preseed file to load all PRESEED_* variables
      source "$PRESEED_FILE"
      SETUP_PRESEED=true
      SETUP_UNATTENDED=false
      echo "Preseed configuration loaded successfully."
    else
      echo "Skipping preseed configuration."
      return
    fi
    
    # Auto-derive DMS settings if not explicitly set
    # If DMS_EMAIL is provided, assume choice 2; if DMS_HOSTNAME is provided, assume choice 1
    if [ -n "${PRESEED_DMS_EMAIL:-}" ]; then
      PRESEED_DMS_CHOICE="2"
    elif [ -n "${PRESEED_DMS_HOSTNAME:-}" ]; then
      PRESEED_DMS_CHOICE="1"
    fi
    
    # If DMS choice is 1 and no hostname, use main FQDN
    if [ "${PRESEED_DMS_CHOICE:-}" = "1" ] && [ -z "${PRESEED_DMS_HOSTNAME:-}" ] && [ -n "${PRESEED_FQDN:-}" ]; then
      PRESEED_DMS_HOSTNAME="$PRESEED_FQDN"
    fi
    
    # If DMS choice is 2 and no email, use certbot email
    if [ "${PRESEED_DMS_CHOICE:-}" = "2" ] && [ -z "${PRESEED_DMS_EMAIL:-}" ] && [ -n "${PRESEED_CERTBOT_EMAIL:-}" ]; then
      PRESEED_DMS_EMAIL="$PRESEED_CERTBOT_EMAIL"
    fi
    
    echo "Preseed configuration loaded successfully."
  fi
}

# Check if a component is already installed (used to determine if preseed applies)
# Returns 0 if NOT installed (preseed can apply), 1 if installed (skip preseed)
is_first_install() {
  local component="$1"
  case "$component" in
    "passwordless_sudoer")
      [ ! -x "/usr/local/bin/passwdls" ]
      ;;
    "webserver")
      ! dpkg -s apache2 php mariadb-server &>/dev/null
      ;;
    "phpmyadmin")
      ! dpkg -s phpmyadmin &>/dev/null
      ;;
    "certbot")
      ! dpkg -s certbot &>/dev/null
      ;;
    "docker_mailserver")
      [ ! -f "/opt/compose/docker-mailserver/compose.yaml" ]
      ;;
    "namecheap")
      if [ -f "/etc/fqdntools/creds.db" ] && command -v sqlite3 >/dev/null 2>&1; then
        ! sqlite3 /etc/fqdntools/creds.db "SELECT 1 FROM creds WHERE provider='namecheap.com' LIMIT 1;" 2>/dev/null | grep -q 1
      else
        return 0  # Not installed
      fi
      ;;
    *)
      return 0  # Default to first install
      ;;
  esac
}

# Load preseed configuration
load_preseed
prompt_with_getinput() {
  local prompt_text="$1"
  local default_val="${2-}"
  local timeout_sec="${3-10}"
  local visibility_mode="${4-visible}"
  local require_confirm="${5-false}"
  local show_confirmation_text="${6-false}"
  local empty_flag="${7-true}"
  local raw result status

  raw=$(
    set -o pipefail
    (
      # Source inside subshell to avoid leaking helper shell options into this script
      source "$ABS_PATH/helpers/getinput.sh"
      getInput "$prompt_text" "$default_val" "$timeout_sec" "$visibility_mode" "$require_confirm" "$show_confirmation_text" "$empty_flag"
    )
  )
  status=$?
  # 200 is special exit code from getinput meaning "user chose to skip"
  if [ $status -eq 200 ]; then
    return 200
  fi
  if [ $status -ne 0 ]; then
    exit $status
  fi

  result=$(printf "%s\n" "$raw" | tail -n1)
  result="${result//$'\r'/}"
  printf "%s" "$result"
}

# init.sh
if [ -d /etc/cryptsetup-keys.d ]; then
  echo "Do you want to execute init.sh first? [y/n]: "
  echo "it is extremely important and even essential for security however
  you only need to run this once for the first time when you install ubuntu server."
  EXECUTE_INIT=$(prompt_with_getinput "Run init.sh now? [y/n]" "y" 5)
  if [ -z "$EXECUTE_INIT" ]; then
    EXECUTE_INIT="y"
  fi
  if [[ "$EXECUTE_INIT" =~ ^[Yy]$ ]]; then
    # Pass SETUP_PRESEED to indicate if preseed was used in setup.sh
    # init.sh will independently ask if user wants preseed there too (only if SETUP_PRESEED=true)
    PRESEED_FILE="$PRESEED_FILE" SETUP_PRESEED="$SETUP_PRESEED" ./init.sh
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

# menu
source "$ABS_PATH/helpers/menu.sh"
main
declare -A OPTIONS
for key in passwordless_sudoer fail2ban_vpn_bypass surfshark webserver apache_domains certbot phpmyadmin roundcube wp_cli pyenv_python podman lazydocker portainer gitea gitea_runner docker_mailserver n8n selenium homeassistant grafana_otel kvm; do
    var_name="OPTION_${key}"
    OPTIONS["$key"]="${!var_name}"
done

trap 'echo -e "\n\nInterrupted by user. Exiting..."; exit 130' INT


prompt_sys_user_action() {
  local service_name="$1"
  local username="$2"
  local var_prefix=$(echo "$service_name" | tr '[:lower:]' '[:upper:]')
  
  if id "$username" &>/dev/null; then
    echo "${service_name^} system user '$username' already exists from a previous installation."
    echo "Options: y=Keep existing | r=Reinstall (delete & recreate) | n=Don't use sys user"
    local action=$(prompt_with_getinput "Choose action [y/r/n]" "y" 15)
    local status=$?
    [ $status -eq 200 ] || [ -z "$action" ] && action="y"
    
    case "$action" in
      [Yy]) eval "${var_prefix}_SYS_USER=true; ${var_prefix}_REINSTALL=false" ;;
      [Rr]) eval "${var_prefix}_SYS_USER=true; ${var_prefix}_REINSTALL=true"
            echo "Will perform complete cleanup and fresh install of $username system user." ;;
      *)    eval "${var_prefix}_SYS_USER=false; ${var_prefix}_REINSTALL=false" ;;
    esac
  else
    eval "${var_prefix}_REINSTALL=false"
    if [ "$SETUP_PRESEED" = true ]; then
      local preseed_var="PRESEED_${var_prefix}_SYS_USER"
      if [ -n "${!preseed_var:-}" ]; then
        if [ "${!preseed_var}" = "1" ]; then
          eval "${var_prefix}_SYS_USER=true"
          echo "Using preseeded ${service_name} system user setting: enabled"
        else
          eval "${var_prefix}_SYS_USER=false"
          echo "Using preseeded ${service_name} system user setting: disabled"
        fi
        return
      fi
    fi
    echo "It is encouraged to create a dedicated system user '$username' to run the ${service_name} container."
    echo "This provides better security and isolation."
    local create=$(prompt_with_getinput "Create system user '$username'? [y/n]" "y" 10)
    local status=$?
    [ $status -eq 200 ] || [ -z "$create" ] && create="y"
    [[ "$create" =~ ^[Yy]$ ]] && eval "${var_prefix}_SYS_USER=true" || eval "${var_prefix}_SYS_USER=false"
  fi
}

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
print_status() {
    local msg="$1"
    local pad_width=50  # Adjust this to fit your longest message
    printf "%-${pad_width}s" "$msg"
}
prompt_main_fqdn_if_needed() {
  if [ "${OPTIONS[apache_domains]}" != "1" ]; then
    return 0
  fi
  
  # Check for preseed value first (only for first install)
  if [ "$SETUP_PRESEED" = true ] && is_first_install "webserver" && [ -n "${PRESEED_FQDN:-}" ]; then
    if is_valid_fqdn "$PRESEED_FQDN"; then
      FQDN="$PRESEED_FQDN"
      echo "Using preseeded FQDN: $FQDN"
      return 0
    else
      echo "Warning: Preseeded FQDN is invalid, falling back to prompt"
    fi
  fi
  
  printf "It is extremely recommended to provide the main FQDN now\n(other programs if also are being installed will be configured in one go).\n"
  ADD_FQDN_NOW=$(prompt_with_getinput "Provide the main FQDN now? [y/n]" "n" 10)
  local status=$?
  if [ $status -eq 200 ] || [ -z "$ADD_FQDN_NOW" ]; then
    ADD_FQDN_NOW="n"
  fi
  if [ "$ADD_FQDN_NOW" = "y" ] || [ "$ADD_FQDN_NOW" = "Y" ]; then
    while true; do
      FQDN=$(prompt_with_getinput "main FQDN" "" 10 "visible" "true" "true" "false")
      status=$?
      if [ $status -eq 200 ]; then
        # user chose to skip
        unset FQDN
        break
      fi
      # Validate FQDN existence
      if [ -z "$FQDN" ]; then
          echo "Error: FQDN can not be empty" >&2
          continue
      fi
      if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
          echo "Error: Invalid FQDN format: $FQDN" >&2
          continue
      fi
      break
    done
  fi
}
get_wan_ip() {
    # Check if WAN_IP is already set in environment
    if [ -n "$WAN_IP" ]; then
        export WAN_IP
        return 0
    fi
    
    # Try to read from /etc/environment
    if [ -f /etc/environment ]; then
        WAN_IP=$(grep -E "^WAN_IP=" /etc/environment 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [ -n "$WAN_IP" ]; then
            export WAN_IP
            return 0
        fi
    fi
    
    # Fetch WAN IP from external service
    WAN_IP=$(curl -s ifconfig.me)
    
    if [ -z "$WAN_IP" ]; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi
    
    # Cache to /etc/environment for system-wide access (requires root)
    if [ "$(id -u)" -eq 0 ]; then
        if grep -q "^WAN_IP=" /etc/environment 2>/dev/null; then
            sed -i "s|^WAN_IP=.*|WAN_IP=\"$WAN_IP\"|" /etc/environment
        else
            echo "WAN_IP=\"$WAN_IP\"" >> /etc/environment
        fi
    fi
    
    export WAN_IP
    return 0
}
get_wan_ip

# prompts first
if [ "${OPTIONS[passwordless_sudoer]}" = "1" ]; then
  # already installed ?
  if [ -x "/usr/local/bin/passwdls" ]; then
    # yes => ask if wants to re-install ? (preseed does NOT apply to reinstalls)
    REINSTALL_SUDO=$(prompt_with_getinput "Passwordless sudoer already installed. Re-install and update secret? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_SUDO" ]; then
      REINSTALL_SUDO="n"
    fi
    if [[ "$REINSTALL_SUDO" =~ ^[Yy]$ ]]; then
      # yes => ask for the needed password
      SUDO_SECRET=$(prompt_with_getinput "Set SUDO protection secret" "" 10 "dotted" "true" "true" "false")
      status=$?
      if [ $status -eq 200 ] || [ -z "$SUDO_SECRET" ]; then
        echo "Skipping sudo secret setup as requested."
        unset SUDO_SECRET
      fi
    else
      # no => skip
      unset SUDO_SECRET
    fi
  else
    # not installed => check preseed first, then prompt
    if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_SUDO_SECRET:-}" ]; then
      SUDO_SECRET="$PRESEED_SUDO_SECRET"
      echo "Using preseeded SUDO protection secret."
    else
      SUDO_SECRET=$(prompt_with_getinput "Set SUDO protection secret" "" 10 "dotted" "true" "true" "false")
      status=$?
      if [ $status -eq 200 ] || [ -z "$SUDO_SECRET" ]; then
        echo "Skipping sudo secret setup as requested."
        unset SUDO_SECRET
      fi
    fi
  fi
fi
if [ "${OPTIONS[fail2ban_vpn_bypass]}" = "1" ]; then
  SKIP_VPN_BYPASS=false
  # already installed?
  if dpkg -s fail2ban &>/dev/null; then
    REINSTALL_VPN_BYPASS=$(prompt_with_getinput "Fail2Ban VPN bypass already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_VPN_BYPASS" ]; then
      REINSTALL_VPN_BYPASS="n"
    fi
    if [[ ! "$REINSTALL_VPN_BYPASS" =~ ^[Yy]$ ]]; then
      SKIP_VPN_BYPASS=true
    fi
  fi
  # only prompt for values if we haven't skipped
  if [ "$SKIP_VPN_BYPASS" = false ]; then
    if [ "$SETUP_PRESEED" = true ]; then
      if [ -z "${PRESEED_YOUR_INTERFACE:-}" ] || \
         [ -z "${PRESEED_YOUR_LAN_SUBNET:-}" ] || \
         [ -z "${PRESEED_YOUR_DEFAULT_GATEWAY:-}" ] || \
         [ -z "${PRESEED_YOUR_PUBLIC_IP:-}" ]; then
        echo "Skipping Fail2Ban VPN bypass: required preseed network values not provided."
      else
        YOUR_INTERFACE="$PRESEED_YOUR_INTERFACE"
        YOUR_LAN_SUBNET="$PRESEED_YOUR_LAN_SUBNET"
        YOUR_DEFAULT_GATEWAY="$PRESEED_YOUR_DEFAULT_GATEWAY"
        YOUR_PUBLIC_IP="$PRESEED_YOUR_PUBLIC_IP"
      fi
    else
      YOUR_INTERFACE=$(prompt_with_getinput "Enter your network interface (e.g., eth0, enp1s0):" "" 0 "visible" "false" "true" "false")
      status=$?
      if [ $status -eq 200 ]; then
        echo "Skipping Fail2Ban VPN bypass as requested."
      else
        YOUR_LAN_SUBNET=$(prompt_with_getinput "Enter your LAN subnet in CIDR notation (e.g., 192.168.0.0/24):" "" 0 "visible" "false" "true" "false")
        status=$?
        if [ $status -eq 200 ]; then
          echo "Skipping Fail2Ban VPN bypass as requested."
        else
          YOUR_DEFAULT_GATEWAY=$(prompt_with_getinput "Enter your router/gateway IP (e.g., 192.168.0.1):" "" 0 "visible" "false" "true" "false")
          status=$?
          if [ $status -eq 200 ]; then
            echo "Skipping Fail2Ban VPN bypass as requested."
          else
            YOUR_PUBLIC_IP=$(prompt_with_getinput "Enter this server's LAN IP (e.g., 192.168.0.2):" "" 0 "visible" "false" "true" "false")
            status=$?
            if [ $status -eq 200 ]; then
              echo "Skipping Fail2Ban VPN bypass as requested."
            fi
          fi
        fi
      fi
    fi
  fi
fi
if [ "${OPTIONS[webserver]}" = "1" ]; then
  # already installed ?
  if dpkg -s apache2 php mariadb-server &>/dev/null; then
    # yes => ask if wants to re-install ?
    REINSTALL_WEBSERVER=$(prompt_with_getinput "Webserver (Apache, PHP, MariaDB) already installed. Re-install webserver stack? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_WEBSERVER" ]; then
      REINSTALL_WEBSERVER="n"
    fi
    if [[ "$REINSTALL_WEBSERVER" =~ ^[Yy]$ ]]; then
      # on reinstall, reuse shared FQDN prompt logic when apache_domains is enabled
      prompt_main_fqdn_if_needed
    fi
  else
    # first-time install: always offer the shared FQDN prompt when apache_domains is enabled
    prompt_main_fqdn_if_needed
  fi
fi
if [ "${OPTIONS[certbot]}" = "1" ]; then
  cert_bot_email_prompt(){
    while true; do
      CERTBOT_EMAIL=$(prompt_with_getinput "certbot email (required when installing certbot)" "" 10 "visible" "false" "true" "false")
      status=$?
      if [ $status -eq 200 ] || [ -z "$CERTBOT_EMAIL" ]; then
        unset CERTBOT_EMAIL
        return 1
      fi
      return 0
    done
  }
  # already installed ?
  if dpkg -s certbot &>/dev/null; then
    # yes => ask if wants to re-install / re-register ? (preseed does NOT apply to reinstalls)
    REINSTALL_CERTBOT=$(prompt_with_getinput "Certbot already installed. Re-run registration and update email? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_CERTBOT" ]; then
      REINSTALL_CERTBOT="n"
    fi
    if [[ "$REINSTALL_CERTBOT" =~ ^[Yy]$ ]]; then
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
            break
          fi
        done
      fi
    else
      unset CERTBOT_EMAIL
    fi
  else
    # not installed => check preseed first, then prompt
    if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_CERTBOT_EMAIL:-}" ]; then
      if is_valid_email "$PRESEED_CERTBOT_EMAIL"; then
        CERTBOT_EMAIL="$PRESEED_CERTBOT_EMAIL"
        echo "Using preseeded certbot email: $CERTBOT_EMAIL"
      else
        echo "Warning: Preseeded certbot email is invalid, falling back to prompt"
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
              break
            fi
          done
        fi
      fi
    else
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
            break
          fi
        done
      fi
    fi
    
    # Only handle Namecheap when certbot email is successfully set
    if [ -n "${CERTBOT_EMAIL:-}" ]; then
      # Only handle Namecheap when certbot is actually being (re)registered
      NAMECHEAP_INSTALLED=false
      # Consider Namecheap installed if there is at least one namecheap.com row in creds.db
      if [ -f "/etc/fqdntools/creds.db" ] && command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 /etc/fqdntools/creds.db "SELECT 1 FROM creds WHERE provider='namecheap.com' LIMIT 1;" 2>/dev/null | grep -q 1; then
          NAMECHEAP_INSTALLED=true
        fi
      fi

      if [ "$NAMECHEAP_INSTALLED" = true ]; then
        # Namecheap API already configured -> ask about re-install / update (preseed does NOT apply)
        ADD_NAMECHEAP=$(prompt_with_getinput "Namecheap API credentials already configured. Re-install / update them now? [y/n]" "n" 10)
        status=$?
        if [ $status -eq 200 ] || [ -z "$ADD_NAMECHEAP" ]; then
          ADD_NAMECHEAP="n"
        fi
        if [ "$ADD_NAMECHEAP" = "y" ] || [ "$ADD_NAMECHEAP" = "Y" ]; then
          while true; do
            NC_USERNAME=$(prompt_with_getinput "Namecheap username" "" 0 "visible" "false" "true" "false")
            status=$?
            if [ $status -eq 200 ] || [ -z "$NC_USERNAME" ]; then
              echo "Skipping Namecheap credentials." >&2
              unset NC_USERNAME NC_API_KEY
              break
            fi
            NC_API_KEY=$(prompt_with_getinput "Namecheap API key" "" 0 "dotted" "false" "true" "false")
            status=$?
            if [ $status -eq 200 ] || [ -z "$NC_API_KEY" ]; then
              echo "Skipping Namecheap credentials." >&2
              unset NC_USERNAME NC_API_KEY
              break
            fi
            break
          done
        fi
      else
        # Namecheap not yet configured -> check preseed first
        if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_NC_USERNAME:-}" ] && [ -n "${PRESEED_NC_API_KEY:-}" ]; then
          NC_USERNAME="$PRESEED_NC_USERNAME"
          NC_API_KEY="$PRESEED_NC_API_KEY"
          echo "Using preseeded Namecheap credentials."
        else
          ADD_NAMECHEAP=$(prompt_with_getinput "Would you like to add Namecheap username and API key now? (extremely helpful) [y/n]" "n" 10)
          status=$?
          if [ $status -eq 200 ] || [ -z "$ADD_NAMECHEAP" ]; then
            ADD_NAMECHEAP="n"
          fi
          if [ "$ADD_NAMECHEAP" = "y" ] || [ "$ADD_NAMECHEAP" = "Y" ]; then
            while true; do
              NC_USERNAME=$(prompt_with_getinput "Namecheap username" "" 0 "visible" "false" "true" "false")
              status=$?
              if [ $status -eq 200 ] || [ -z "$NC_USERNAME" ]; then
                echo "Skipping Namecheap credentials." >&2
                unset NC_USERNAME NC_API_KEY
                break
              fi
              NC_API_KEY=$(prompt_with_getinput "Namecheap API key" "" 0 "dotted" "false" "true" "false")
              status=$?
              if [ $status -eq 200 ] || [ -z "$NC_API_KEY" ]; then
                echo "Skipping Namecheap credentials." >&2
                unset NC_USERNAME NC_API_KEY
                break
              fi
              break
            done
          fi
        fi
      fi
      
      # Prompt for DNS setup (only when Namecheap credentials are provided)
      if [ -n "${NC_USERNAME:-}" ] && [ -n "${NC_API_KEY:-}" ]; then
        # Check for preseed value first
        if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_SETUP_DNS:-}" ]; then
          SETUP_DNS="$PRESEED_SETUP_DNS"
          echo "Using preseeded DNS setup choice: $SETUP_DNS"
        else
          SETUP_DNS=$(prompt_with_getinput "Set initial DNS records for all Namecheap domains? [Y/n]" "Y" 10)
          status=$?
          if [ $status -eq 200 ] || [ -z "$SETUP_DNS" ]; then
            SETUP_DNS="Y"
          fi
        fi
        
        # For interactive mode, we'll handle fqdnmgr prompts during install phase
        # For preseed mode, store the selection
        if [[ "$SETUP_DNS" =~ ^[Yy] ]]; then
          if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_DNS_SELECTION:-}" ]; then
            DNS_SELECTION="$PRESEED_DNS_SELECTION"
            echo "Using preseeded DNS selection: $DNS_SELECTION"
          fi
          RUN_DNS_SETUP=true
        else
          RUN_DNS_SETUP=false
        fi
      fi
    fi
  fi
fi
if [ "${OPTIONS[phpmyadmin]}" = "1" ]; then
  # already installed ?
  if dpkg -s phpmyadmin &>/dev/null; then
    # yes => ask if wants to re-install ? (preseed does NOT apply to reinstalls)
    REINSTALL_PMA=$(prompt_with_getinput "phpMyAdmin already installed. Re-install and reconfigure DB user password? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_PMA" ]; then
      REINSTALL_PMA="n"
    fi
    if [[ "$REINSTALL_PMA" =~ ^[Yy]$ ]]; then
      while true; do
        PHPMYADMIN_SECRET=$(prompt_with_getinput "Set phpMyAdmin database user password" "" 10 "dotted" "true" "true" "false")
        status=$?
        if [ $status -eq 200 ] || [ -z "$PHPMYADMIN_SECRET" ]; then
          unset PHPMYADMIN_SECRET
          break
        fi
        break
      done
    else
      unset PHPMYADMIN_SECRET
    fi
  else
    # not installed => check preseed first, then prompt
    if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_PHPMYADMIN_SECRET:-}" ]; then
      PHPMYADMIN_SECRET="$PRESEED_PHPMYADMIN_SECRET"
      echo "Using preseeded phpMyAdmin database user password."
    else
      while true; do
        PHPMYADMIN_SECRET=$(prompt_with_getinput "Set phpMyAdmin database user password" "" 10 "dotted" "true" "true" "false")
        status=$?
        if [ $status -eq 200 ] || [ -z "$PHPMYADMIN_SECRET" ]; then
          unset PHPMYADMIN_SECRET
          break
        fi
        break
      done
    fi
  fi
fi
if [ "${OPTIONS[docker_mailserver]}" = "1" ]; then
  # already set up ?
  if [ -f "/opt/compose/docker-mailserver/compose.yaml" ]; then
    # yes => ask if wants to re-install ? (preseed does NOT apply to reinstalls)
    REINSTALL_DMS=$(prompt_with_getinput "Docker Mailserver already set up. Re-install and reconfigure hostname/email? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_DMS" ]; then
      REINSTALL_DMS="n"
    fi
    SKIP_DMS=false
    if [[ ! "$REINSTALL_DMS" =~ ^[Yy]$ ]]; then
      SKIP_DMS=true
    fi
  else
    # not installed => check preseed first
    SKIP_DMS=false
    if [ "$SETUP_PRESEED" = true ]; then
      # Preseed logic for DMS - derive choice from what's provided
      if [ -n "${PRESEED_DMS_EMAIL:-}" ]; then
        if is_valid_email "$PRESEED_DMS_EMAIL"; then
          DMS_EMAIL="$PRESEED_DMS_EMAIL"
          DMS_FQDN="${PRESEED_DMS_EMAIL#*@}"
          echo "Using preseeded Docker Mailserver email: $DMS_EMAIL"
          # Check for preseed password
          if [ -n "${PRESEED_DMS_EMAIL_PASSWORD:-}" ]; then
            DMS_EMAIL_PASSWORD="$PRESEED_DMS_EMAIL_PASSWORD"
            echo "Using preseeded Docker Mailserver email password."
          else
            echo "Warning: No preseed password for DMS email, will skip email account creation."
          fi
          SKIP_DMS=false
        else
          echo "Warning: Preseeded DMS email is invalid, falling back to prompt"
        fi
      elif [ -n "${PRESEED_DMS_HOSTNAME:-}" ]; then
        if is_valid_fqdn "$PRESEED_DMS_HOSTNAME"; then
          DMS_HOSTNAME="$PRESEED_DMS_HOSTNAME"
          echo "Using preseeded Docker Mailserver hostname: $DMS_HOSTNAME"
          SKIP_DMS=false
        else
          echo "Warning: Preseeded DMS hostname is invalid, falling back to prompt"
        fi
      elif [ "${PRESEED_DMS_CHOICE:-}" = "c" ] || [ "${PRESEED_DMS_CHOICE:-}" = "C" ]; then
        # Explicitly skipped in preseed
        SKIP_DMS=true
      fi
      # If DMS values were set from preseed, skip the interactive prompts
      if [ -n "${DMS_EMAIL:-}" ] || [ -n "${DMS_HOSTNAME:-}" ]; then
        SKIP_DMS=false
      fi
    fi
  fi
  # Only show interactive prompts if preseed didn't provide valid values
  if [ "$SKIP_DMS" = false ] && [ -z "${DMS_EMAIL:-}" ] && [ -z "${DMS_HOSTNAME:-}" ]; then
    while true; do  
      printf "\rdocker mailserver requires a hostname at least, that or provide an email
        1- hostname (FQDN)
        2- email (recommended)
        provide a number or c to cancel\n"

      DMS_CHOICE=$(prompt_with_getinput "Select 1 for hostname, 2 for email, or c to cancel" "c" 10)
      status=$?
      if [ $status -eq 200 ] || [ -z "$DMS_CHOICE" ]; then
        # user chose to skip at the main choice prompt
        SKIP_DMS=true
        break
      fi
      if [ "$DMS_CHOICE" = "c" ] || [ "$DMS_CHOICE" = "C" ]; then
        # explicit cancel treated as skip
        SKIP_DMS=true
        break
      elif [ "$DMS_CHOICE" = "1" ]; then
        # User chose hostname (FQDN)
        while true; do
          # If a main FQDN was provided earlier, ask whether to reuse it
          if [ -n "${FQDN:-}" ]; then
            USE_EXISTING_FQDN=$(prompt_with_getinput "Use previously provided FQDN ($FQDN) for docker mailserver? [y/n]" "y" 10)
            status=$?
            if [ $status -eq 200 ]; then
              # treat skip here as not using existing FQDN; continue to prompt for a new one
              USE_EXISTING_FQDN="n"
            fi
            if [[ "$USE_EXISTING_FQDN" =~ ^[Yy]$ ]]; then
              DMS_FQDN="$FQDN"
              break 2
            fi
          fi
          DMS_FQDN_INPUT=$(prompt_with_getinput "Enter FQDN for docker mailserver" "" 10 "visible" "false" "true" "false")
          status=$?
          if [ $status -eq 200 ]; then
            # user chose to skip
            SKIP_DMS=true
            break 2
          fi
          if is_valid_fqdn "$DMS_FQDN_INPUT"; then
            # Valid FQDN provided
            DMS_FQDN="$DMS_FQDN_INPUT"
            break 2  # Break out of both loops
          else
            # Invalid FQDN; loop back unless user uses skip
            echo "Error: Invalid FQDN format: $DMS_FQDN_INPUT" >&2
          fi
        done
      elif [ "$DMS_CHOICE" = "2" ]; then
        # User chose email
        while true; do
          # Check if certbot email was provided earlier
          if [ -n "${CERTBOT_EMAIL:-}" ]; then
            USE_CERTBOT_EMAIL=$(prompt_with_getinput "Use the same previous email ($CERTBOT_EMAIL)? [y/n]" "y" 10)
            status=$?
            if [ $status -eq 200 ]; then
              # treat skip here as not using existing email, continue to prompt
              USE_CERTBOT_EMAIL="n"
            fi
            if [ "$USE_CERTBOT_EMAIL" = "y" ] || [ "$USE_CERTBOT_EMAIL" = "Y" ]; then
              DMS_EMAIL="$CERTBOT_EMAIL"
              # Extract domain from email for DMS_FQDN
              DMS_FQDN="${CERTBOT_EMAIL#*@}"
              # Prompt for email account password
              while true; do
                DMS_EMAIL_PASSWORD=$(prompt_with_getinput "Enter password for email account $DMS_EMAIL" "" 0 "dotted" "true" "true" "false")
                status=$?
                if [ $status -eq 200 ]; then
                  # user chose to skip - cancel DMS setup
                  SKIP_DMS=true
                  unset DMS_EMAIL DMS_FQDN
                  break 3
                fi
                if [ -n "$DMS_EMAIL_PASSWORD" ]; then
                  break
                fi
                echo "Password cannot be empty. Please try again or press ESC to skip DMS setup." >&2
              done
              break 2  # Break out of both loops
            fi
          fi
          DMS_EMAIL_INPUT=$(prompt_with_getinput "Enter email for docker mailserver" "" 10 "visible" "false" "true" "false")
          status=$?
          if [ $status -eq 200 ]; then
            # user chose to skip email entry
            SKIP_DMS=true
            break 2
          fi
          if is_valid_email "$DMS_EMAIL_INPUT"; then
            # Valid email provided
            DMS_EMAIL="$DMS_EMAIL_INPUT"
            # Extract domain from email for DMS_FQDN
            DMS_FQDN="${DMS_EMAIL_INPUT#*@}"
            # Prompt for email account password
            while true; do
              DMS_EMAIL_PASSWORD=$(prompt_with_getinput "Enter password for email account $DMS_EMAIL" "" 0 "dotted" "true" "true" "false")
              status=$?
              if [ $status -eq 200 ]; then
                # user chose to skip - cancel DMS setup
                SKIP_DMS=true
                unset DMS_EMAIL DMS_FQDN
                break 3
              fi
              if [ -n "$DMS_EMAIL_PASSWORD" ]; then
                break
              fi
              echo "Password cannot be empty. Please try again or press ESC to skip DMS setup." >&2
            done
            break 2  # Break out of both loops
          else
            # Invalid email; loop back unless user uses skip
            echo "Error: Email format is invalid" >&2
          fi
        done
      else
        # Invalid choice; let user retry via loop, or use skip at prompt
        echo "Error: Invalid choice. Please enter 1, 2, or c" >&2
        # loop will re-run and user can use ESC to skip at the main choice prompt
      fi
    done
  fi
  # Prompt for DMS system user with reinstall option
  prompt_sys_user_action "DMS" "dms"
fi
if [ "${OPTIONS[gitea]}" = "1" ]; then
  prompt_sys_user_action "Gitea" "gitea"
fi
if [ "${OPTIONS[gitea_runner]}" = "1" ]; then
  # Check preseed first, then prompt for GITEA_USERNAME
  if [ "$SETUP_PRESEED" = true ] && [ -n "${PRESEED_GITEA_USERNAME:-}" ]; then
    GITEA_USERNAME="$PRESEED_GITEA_USERNAME"
    echo "Using preseeded Gitea username: $GITEA_USERNAME"
  else
    GITEA_USERNAME=$(prompt_with_getinput "Gitea admin username for Act Runner tokens" "" 10 "visible" "false" "true" "false")
    status=$?
    if [ $status -eq 200 ] || [ -z "$GITEA_USERNAME" ]; then
      echo "Warning: No Gitea username provided. giteaGetTokens.sh will need manual configuration."
      unset GITEA_USERNAME
    fi
  fi
fi
if [ "${OPTIONS[n8n]}" = "1" ]; then
  prompt_sys_user_action "n8n" "n8n"
fi
if [ "${OPTIONS[surfshark]}" = "1" ]; then
  if dpkg -s surfshark &>/dev/null; then
    REINSTALL_SURFSHARK=$(prompt_with_getinput "Surfshark already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_SURFSHARK" ]; then
      REINSTALL_SURFSHARK="n"
    fi
  fi
fi
if [ "${OPTIONS[apache_domains]}" = "1" ]; then
  if command -v a2sitemgr >/dev/null 2>&1 && \
     command -v fqdncredmgr >/dev/null 2>&1 && \
     command -v fqdnmgr >/dev/null 2>&1 && \
     command -v a2wcrecalc >/dev/null 2>&1; then
    REINSTALL_APACHE_DOMAINS=$(prompt_with_getinput "Apache domain management tools already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_APACHE_DOMAINS" ]; then
      REINSTALL_APACHE_DOMAINS="n"
    fi
  fi
fi
if [ "${OPTIONS[roundcube]}" = "1" ]; then
  if [ -d "/var/www/mail" ]; then
    REINSTALL_ROUNDCUBE=$(prompt_with_getinput "Roundcube webmail already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_ROUNDCUBE" ]; then
      REINSTALL_ROUNDCUBE="n"
    fi
  fi
fi
if [ "${OPTIONS[wp_cli]}" = "1" ]; then
  if [ -x "/usr/local/bin/wp" ]; then
    REINSTALL_WP_CLI=$(prompt_with_getinput "WP-CLI already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_WP_CLI" ]; then
      REINSTALL_WP_CLI="n"
    fi
  fi
fi
if [ "${OPTIONS[pyenv_python]}" = "1" ]; then
  if [ -n "$SUDO_USER" ]; then
    if sudo -u "$SUDO_USER" bash -lc '
      export PYENV_ROOT="$HOME/.pyenv"
      [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
      command -v pyenv >/dev/null 2>&1 || exit 1
      eval "$(pyenv init - bash)" >/dev/null 2>&1 || true
      pyenv versions 2>/dev/null | grep -q "3\.13"
    '; then
      REINSTALL_PYENV=$(prompt_with_getinput "Pyenv and Python 3.13 already installed. Re-install? [y/n]" "n" 10)
      status=$?
      if [ $status -eq 200 ] || [ -z "$REINSTALL_PYENV" ]; then
        REINSTALL_PYENV="n"
      fi
    fi
  fi
fi
if [ "${OPTIONS[podman]}" = "1" ]; then
  if command -v podman &>/dev/null; then
    REINSTALL_PODMAN=$(prompt_with_getinput "Podman already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_PODMAN" ]; then
      REINSTALL_PODMAN="n"
    fi
  fi
fi
if [ "${OPTIONS[lazydocker]}" = "1" ]; then
  if [ -x "/usr/bin/lazydocker" ]; then
    REINSTALL_LAZYDOCKER=$(prompt_with_getinput "LazyDocker already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_LAZYDOCKER" ]; then
      REINSTALL_LAZYDOCKER="n"
    fi
  fi
fi
if [ "${OPTIONS[portainer]}" = "1" ]; then
  if podman volume inspect portainer_data &>/dev/null && [ -f "/opt/compose/portainer/compose.yaml" ]; then
    REINSTALL_PORTAINER=$(prompt_with_getinput "Portainer already set up. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_PORTAINER" ]; then
      REINSTALL_PORTAINER="n"
    fi
  fi
fi
if [ "${OPTIONS[kvm]}" = "1" ]; then
  if command -v virt-install-ubuntu &>/dev/null; then
    REINSTALL_KVM=$(prompt_with_getinput "KVM/QEMU already installed. Re-install? [y/n]" "n" 10)
    status=$?
    if [ $status -eq 200 ] || [ -z "$REINSTALL_KVM" ]; then
      REINSTALL_KVM="n"
    fi
  fi
fi

print_status "Updating package lists and upgrading existing packages, this will take a moment... "
{
  apt update && apt upgrade -y 
} >>./log 2>&1
echo

# the actual install logic.
if [ -n "$SUDO_SECRET" ]; then
  if [ -x "/usr/local/bin/passwdls" ]; then
    print_status "Passwordless sudoer already installed. Skipping... "
    echo
  else
    print_status "Installing passwordless sudoer... "
    # pass SUDO_SECRET into the helper's environment without exporting it globally
    SUDO_SECRET="$SUDO_SECRET" bash ./helpers/passwdless_sudoer.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[surfshark]}" = "1" ]; then
  if dpkg -s surfshark &>/dev/null && [[ ! "${REINSTALL_SURFSHARK:-n}" =~ ^[Yy]$ ]]; then
    print_status "surfshark already installed. Skipping... "
    echo
  else
    print_status "Installing surfshark... "
    {
      curl -f https://downloads.surfshark.com/linux/debian-install.sh --output surfshark-install.sh
      sed -i '/^\$SUDO apt-get install -y surfshark$/,$d' surfshark-install.sh
      sh surfshark-install.sh
      sudo apt-get install surfshark-vpn -y
    } >>./log 2>&1 &
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
      a2enmod proxy_fcgi setenvif rewrite ssl proxy_http
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
  TOOLS_INSTALLED=false
  if command -v a2sitemgr >/dev/null 2>&1 && \
     command -v fqdncredmgr >/dev/null 2>&1 && \
     command -v fqdnmgr >/dev/null 2>&1 && \
     command -v a2wcrecalc >/dev/null 2>&1; then
    TOOLS_INSTALLED=true
  fi
  if [ "$TOOLS_INSTALLED" = true ] && [[ ! "${REINSTALL_APACHE_DOMAINS:-n}" =~ ^[Yy]$ ]]; then
    print_status "Apache domain management tools already installed. Skipping... "
    echo
  else
    print_status "Installing Apache domain management tools... "
    {
      apt install -y whois sqlite3 libxml2-utils jq
      rm -rf a2tools
      mkdir a2tools && cd a2tools
      git clone https://github.com/TBAIKamine/a2tools.git .
      bash ./setup.sh
      hash -r
      cd ..
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
print_status "Installing fsubid... "
{
  mkdir -p /usr/local/bin/fsubid.d
  cp "$ABS_PATH/helpers/fsubid.d/fsubid.sh" /usr/local/bin/fsubid.d/
  cp "$ABS_PATH/helpers/fsubid.d/usage.txt" /usr/local/bin/fsubid.d/
  chmod +x /usr/local/bin/fsubid.d/fsubid.sh
  ln -sf /usr/local/bin/fsubid.d/fsubid.sh /usr/local/bin/fsubid
} >>./log 2>&1
echo "Done"
print_status "Installing podmgr... "
{
  mkdir -p /usr/local/bin/podmgr.d
  cp "$ABS_PATH/helpers/podmgr.d/podmgr.sh" /usr/local/bin/podmgr.d/
  cp "$ABS_PATH/helpers/podmgr.d/usage.txt" /usr/local/bin/podmgr.d/
  cp "$ABS_PATH/helpers/podmgr.d/podman-compose.service.tpl" /usr/local/bin/podmgr.d/
  chmod +x /usr/local/bin/podmgr.d/podmgr.sh
  ln -sf /usr/local/bin/podmgr.d/podmgr.sh /usr/local/bin/podmgr
} >>./log 2>&1
echo "Done"
if [ "${OPTIONS[certbot]}" = "1" ]; then
  if dpkg -s certbot &>/dev/null; then
    print_status "Certbot already installed. Skipping... "
    echo
  else
    print_status "Installing Certbot... "
    {
      apt install certbot -y >>/dev/null 2>&1
      if [ -n "$CERTBOT_EMAIL" ]; then
        certbot register --agree-tos --non-interactive --no-eff-email --email "$CERTBOT_EMAIL" >>./log 2>&1
      fi
    }
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ -n "${NC_USERNAME:-}" ] && [ -n "${NC_API_KEY:-}" ]; then
  {
    # credentials manager
    if ! command -v fqdncredmgr &>/dev/null; then
      echo "Error: fqdncredmgr command not found after certbot installation." >&2
    elif [ -n "$NC_USERNAME" ] && [ -n "$NC_API_KEY" ]; then
      fqdncredmgr add namecheap.com "$NC_USERNAME" -p "$NC_API_KEY"
    fi
  } >>./log 2>&1
  # Wait for credentials to be saved before running DNS init
  wait
  
  # Run DNS setup if user opted in during prompts phase
  if [ "${RUN_DNS_SETUP:-false}" = true ] && command -v fqdnmgr &>/dev/null; then
    if [ "$SETUP_PRESEED" = true ] && [ -n "${DNS_SELECTION:-}" ]; then
      echo "Starting DNS initialization for namecheap domains in background..."
      fqdnmgr setInitDNSRecords -r namecheap.com >>./log 2>&1 &
    else
      # Interactive mode - let the user see and interact with the prompts
      fqdnmgr setInitDNSRecords -r namecheap.com
    fi
  fi
fi
if [ "${OPTIONS[phpmyadmin]}" = "1" ]; then
    if [ -n "$PHPMYADMIN_SECRET" ]; then
      if dpkg -s phpmyadmin &>/dev/null; then
        print_status "phpMyAdmin already installed. Skipping... "
        echo
      else
        print_status "Installing phpMyAdmin... "
        {
          apt install dbconfig-common -y
          export DEBIAN_FRONTEND=noninteractive
          debconf-set-selections <<< "phpmyadmin phpmyadmin/dbconfig-install boolean true"
          debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/app-pass password $PHPMYADMIN_SECRET"
          debconf-set-selections <<< "phpmyadmin phpmyadmin/password-confirm password $PHPMYADMIN_SECRET"
          debconf-set-selections <<< "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2"
          apt install phpmyadmin -y
        } >>./log 2>&1 &
        bash ./helpers/progress.sh $!
        echo
      fi
    fi
fi
if [ "${OPTIONS[wp_cli]}" = "1" ]; then
  if [ -x "/usr/local/bin/wp" ] && [[ ! "${REINSTALL_WP_CLI:-n}" =~ ^[Yy]$ ]]; then
    print_status "WP-CLI already installed. Skipping... "
    echo
  else
    print_status "Installing WP-CLI... "
    {
      curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
      chmod +x wp-cli.phar
      mv wp-cli.phar /usr/local/bin/wp
      chown $SUDO_USER:$SUDO_USER /usr/local/bin/wp
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[pyenv_python]}" = "1" ]; then
  # Check pyenv/Python from the perspective of the normal user, not root
  if [ -n "$SUDO_USER" ]; then
    PYENV_INSTALLED=false
    if sudo -u "$SUDO_USER" bash -lc '
      export PYENV_ROOT="$HOME/.pyenv"
      [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
      command -v pyenv >/dev/null 2>&1 || exit 1
      eval "$(pyenv init - bash)" >/dev/null 2>&1 || true
      pyenv versions 2>/dev/null | grep -q "3\.13"
    '; then
      PYENV_INSTALLED=true
    fi
    if [ "$PYENV_INSTALLED" = true ] && [[ ! "${REINSTALL_PYENV:-n}" =~ ^[Yy]$ ]]; then
      print_status "Pyenv and Python 3.13 already installed. Skipping... "
      echo
    else
      print_status "Installing Pyenv and Python 3.13... "
      {
        apt install make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev curl git \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev -y
        sudo -u $SUDO_USER bash -c 'curl -fsSL https://pyenv.run | bash'
        cat ./helpers/pyenv_profile.txt >> /home/$SUDO_USER/.bashrc
        echo "export PYENV_ROOT=\"/home/$SUDO_USER/.pyenv\"" >> /home/$SUDO_USER/.bashrc
        [[ -d /home/$SUDO_USER/.pyenv/bin ]] && echo "export PATH=\"$PYENV_ROOT/bin:\$PATH\"" >> /home/$SUDO_USER/.bashrc
        hash -r #refresh environment
        sudo -u $SUDO_USER bash -l -c '
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
fi
if [ "${OPTIONS[fail2ban_vpn_bypass]}" = "1" ]; then
  # Values must have been collected during the '# prompts first' phase.
  # Helper is idempotent, so safe to re-run (no duplicate rules).
  if [ -n "${YOUR_INTERFACE:-}" ] && \
     [ -n "${YOUR_LAN_SUBNET:-}" ] && \
     [ -n "${YOUR_DEFAULT_GATEWAY:-}" ] && \
     [ -n "${YOUR_PUBLIC_IP:-}" ]; then
    print_status "Installing Fail2Ban VPN bypass... "
    {
      YOUR_INTERFACE="$YOUR_INTERFACE" \
      YOUR_LAN_SUBNET="$YOUR_LAN_SUBNET" \
      YOUR_DEFAULT_GATEWAY="$YOUR_DEFAULT_GATEWAY" \
      YOUR_PUBLIC_IP="$YOUR_PUBLIC_IP" \
      bash ./helpers/vpn_bypass.sh
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  else
    # skipped earlier (preseed values missing or user chose skip)
    echo
  fi
fi
if [ "${OPTIONS[podman]}" = "1" ]; then
  if command -v podman &>/dev/null && [[ ! "${REINSTALL_PODMAN:-n}" =~ ^[Yy]$ ]]; then
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
  if [ -x "/usr/bin/lazydocker" ] && [[ ! "${REINSTALL_LAZYDOCKER:-n}" =~ ^[Yy]$ ]]; then
    print_status "LazyDocker already installed. Skipping... "
    echo
  else
    print_status "Installing LazyDocker... "
    {
      export DIR=/usr/bin; curl -sL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | sudo DIR=$DIR bash
      chown $SUDO_USER:$SUDO_USER /usr/bin/lazydocker
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[portainer]}" = "1" ]; then
  PORTAINER_INSTALLED=false
  if podman volume inspect portainer_data &>/dev/null && [ -f "/opt/compose/portainer/compose.yaml" ]; then
    PORTAINER_INSTALLED=true
  fi
  if [ "$PORTAINER_INSTALLED" = true ] && [[ ! "${REINSTALL_PORTAINER:-n}" =~ ^[Yy]$ ]]; then
    print_status "Portainer already set up. Skipping... "
    echo
  else
    print_status "Installing Portainer... "
    {
      podman volume create portainer_data
      if [ -n "$FQDN" ]; then
        a2sitemgr -d "portainer.$FQDN" --mode proxypass -s -p 9443
      fi
      mkdir -p /opt/compose/portainer/agents
      # If a main FQDN was provided, expand the placeholder in the template.
      # Otherwise remove the TRUSTED_ORIGINS entry to avoid invalid env var.
      SUDO_UID=$(id -u "$SUDO_USER")
      if [ -n "$FQDN" ]; then
        sed -e "s|\$FQDN|$FQDN|g" -e "s|__UID__|$SUDO_UID|g" "$ABS_PATH/helpers/portainer-compose.yaml" > /opt/compose/portainer/compose.yaml
      else
        tmpfile=$(mktemp)
        sed "s|__UID__|$SUDO_UID|g" "$ABS_PATH/helpers/portainer-compose.yaml" | grep -v 'TRUSTED_ORIGINS' > "$tmpfile"
        # If the environment block is left without any `-` entries, remove the environment: line too.
        awk '
        {
          if ($0 ~ /^[[:space:]]*environment:/) {
            if (getline nxt) {
              if (nxt ~ /^[[:space:]]*-/) {
                print $0
                print nxt
              } else {
                print nxt
              }
            }
          } else {
            print $0
          }
        }
        ' "$tmpfile" > /opt/compose/portainer/compose.yaml
        rm -f "$tmpfile"
      fi
      cp $ABS_PATH/helpers/portainer-agent.yaml /opt/compose/portainer/agents/compose.yaml
      cp $ABS_PATH/helpers/portainer-readme.md /opt/compose/portainer/agents/README.md
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[docker_mailserver]}" = "1" ]; then
  if [[ "${REINSTALL_DMS:-n}" =~ ^[Yy]$ ]] || [ "${DMS_REINSTALL:-false}" = true ]; then
    print_status "Performing complete DMS cleanup for reinstall... "
    podmgr cleanup --user dms --compose-dir /opt/compose/docker-mailserver >>./log 2>&1
    echo "Done"
  fi
  
  if [ -f "/opt/compose/docker-mailserver/compose.yaml" ] && [[ ! "${REINSTALL_DMS:-n}" =~ ^[Yy]$ ]]; then
    print_status "Docker Mailserver already set up. Skipping... "
    echo
  else
    print_status "Installing Docker Mailserver... "
    # pass DMS_EMAIL/DMS_HOSTNAME/DMS_SYS_USER/DMS_EMAIL_PASSWORD into the helper's environment so it can use them
    DMS_EMAIL="${DMS_EMAIL:-}" DMS_FQDN="${DMS_FQDN:-}" DMS_SYS_USER="${DMS_SYS_USER:-false}" DMS_EMAIL_PASSWORD="${DMS_EMAIL_PASSWORD:-}" bash ./helpers/dms_install.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[docker_mailserver]}" = "1" ] && [ "${OPTIONS[webserver]}" = "1" ] && [ "${OPTIONS[apache_domains]}" = "1" ]; then
  if [ -x "/usr/local/bin/a2wcrecalc-dms.d/a2wcrecalc-dms.sh" ]; then
    print_status "DMS Apache integration tool already installed. Skipping... "
    echo
  else
    print_status "Installing DMS Apache integration tool... "
    {
      mkdir a2tools && cd a2tools
      git clone https://github.com/TBAIKamine/a2tools.git .
      bash ./setup.sh
      hash -r
      cd ..
    } >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[gitea]}" = "1" ]; then
  if [ "${GITEA_REINSTALL:-false}" = true ]; then
    print_status "Performing complete Gitea cleanup for reinstall... "
    podmgr cleanup --user gitea >>./log 2>&1
    echo "Done"
  fi
  
  if [ -f "/opt/compose/gitea/compose.yaml" ] && [ "${GITEA_REINSTALL:-false}" = false ]; then
    print_status "Gitea already set up. Skipping... "
    echo
  else
    print_status "Installing Gitea... "
    FQDN="$FQDN" GITEA_SYS_USER="${GITEA_SYS_USER:-false}" bash ./helpers/gitea_install.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[kvm]}" = "1" ]; then
  if command -v virt-install-ubuntu &>/dev/null && [[ ! "${REINSTALL_KVM:-n}" =~ ^[Yy]$ ]]; then
    print_status "KVM/QEMU already installed. Skipping... "
    echo
  else
    print_status "Installing KVM/QEMU virtualization... "
    bash ./helpers/kvm.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
if [ "${OPTIONS[gitea_runner]}" = "1" ]; then
  print_status "Installing Gitea Act Runner... "
  FQDN="$FQDN" GITEA_USERNAME="${GITEA_USERNAME:-}" ABS_PATH="$ABS_PATH" bash ./helpers/runner_install.sh >>./log 2>&1 &
  bash ./helpers/progress.sh $!
  echo
fi
if [ "${OPTIONS[n8n]}" = "1" ]; then
  if [ "${N8N_REINSTALL:-false}" = true ]; then
    print_status "Performing complete n8n cleanup for reinstall... "
    podmgr cleanup --user n8n >>./log 2>&1
    echo "Done"
  fi
  
  if [ -f "/opt/compose/n8n/compose.yaml" ] && [ "${N8N_REINSTALL:-false}" = false ]; then
    print_status "n8n already set up. Skipping... "
    echo
  else
    print_status "Installing n8n... "
    FQDN="$FQDN" N8N_SYS_USER="${N8N_SYS_USER:-false}" bash ./helpers/n8n_install.sh >>./log 2>&1 &
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
if [ "${OPTIONS[roundcube]}" = "1" ]; then
  if [ -d "/var/www/mail" ] && [[ ! "${REINSTALL_ROUNDCUBE:-n}" =~ ^[Yy]$ ]]; then
    print_status "Roundcube webmail already installed. Skipping... "
    echo
  else
    print_status "Installing Roundcube webmail... "
    # pass FQDN into the helper so it can configure vhosts when provided
    FQDN="$FQDN" bash ./helpers/roundcube_install.sh >>./log 2>&1 &
    bash ./helpers/progress.sh $!
    echo
  fi
fi
# cleanup
dms_acl_hook() {
  # Only set ACLs if the dms user exists
  if id "dms" &>/dev/null; then
    setfacl -R -m u:dms:rx /etc/letsencrypt/live
    setfacl -R -m u:dms:rx /etc/letsencrypt/archive
    setfacl -R -d -m u:dms:rx /etc/letsencrypt/live
    setfacl -R -d -m u:dms:rx /etc/letsencrypt/archive
  fi
}
if [ "${OPTIONS[docker_mailserver]}" = "1" ]; then
  if [ -d "/etc/letsencrypt/live" ]; then
    dms_acl_hook >>./log 2>&1
    a2wcrecalc-dms >>./log 2>&1
  fi
fi
# TODO: must have containers: supabase, appwrite
echo -e "\nSetup complete!"
#!/bin/bash
set -e

ABS_PATH=$(dirname "$(realpath "$0")")

show_usage() {
  cat "$ABS_PATH/usage.txt"
  exit 0
}

run_hook() {
  local hook="$1"
  [ -z "$hook" ] && return 0
  if [ -f "$hook" ]; then
    echo "Running hook from file: $hook"
    if ! source "$hook"; then
      echo "ERROR: Hook file '$hook' failed with exit code $?" >&2
      return 1
    fi
  elif declare -f "$hook" >/dev/null 2>&1; then
    echo "Running hook function: $hook"
    if ! "$hook"; then
      echo "ERROR: Hook function '$hook' failed with exit code $?" >&2
      return 1
    fi
  else
    echo "ERROR: Hook '$hook' is neither a file nor a declared function" >&2
    return 1
  fi
}

get_user_env() {
  local user="$1"
  echo "/var/lib/$user/.config/environment.d/podman.conf"
}

run_as_user() {
  local user="$1"
  shift
  local env_file=$(get_user_env "$user")
  local compose_dir="${COMPOSE_DIR:-/opt/compose/$user}"
  local home_dir="/var/lib/$user"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && cd '$compose_dir' && $*"
}

do_setup() {
  local user="$1" compose_dir="$2" hook="$3"
  local home_dir="/var/lib/$user"
  local service_name="$user.service"

  id "$user" >/dev/null 2>&1 || useradd -r -d "$home_dir" -s /usr/sbin/nologin "$user"
  local uid_num=$(id -u "$user")

  mkdir -p "$home_dir/.config/systemd/user" "$home_dir/.config/environment.d" "$home_dir/.local/share"

  local env_file="$home_dir/.config/environment.d/podman.conf"
  # Note: systemd environment.d files use KEY=VALUE format, NOT 'export KEY=VALUE'
  cat > "$env_file" <<EOF
XDG_RUNTIME_DIR=/run/user/$uid_num
DOCKER_HOST=unix:///run/user/$uid_num/podman/podman.sock
export XDG_RUNTIME_DIR DOCKER_HOST
EOF
  chown -R "$user:$user" "$home_dir"

  loginctl enable-linger "$user" 2>/dev/null || true

  local subid_range=$(fsubid "$user")
  # Convert START:SIZE to START-END format for usermod
  local subid_start=$(echo "$subid_range" | cut -d: -f1)
  local subid_size=$(echo "$subid_range" | cut -d: -f2)
  local subid_end=$((subid_start + subid_size - 1))
  local usermod_range="${subid_start}-${subid_end}"
  grep -q "^$user:" /etc/subuid 2>/dev/null || usermod --add-subuids "$usermod_range" "$user"
  grep -q "^$user:" /etc/subgid 2>/dev/null || usermod --add-subgids "$usermod_range" "$user"
  sudo -u "$user" -H bash -c "cd '$home_dir' && podman system migrate" 2>/dev/null || true

  [ -d "$compose_dir" ] && chown -R "$user:$user" "$compose_dir"

  local target_unit="$home_dir/.config/systemd/user/$service_name"
  sed -e "s|\$COMPOSE_DIR|$compose_dir|g" -e "s|\$USER|$user|g" "$ABS_PATH/podman-compose.service.tpl" > "$target_unit"
  chown "$user:$user" "$target_unit"

  systemctl start "user@$uid_num.service" 2>/dev/null || true

  local wait_count=0
  while [ ! -d "/run/user/$uid_num" ] && [ $wait_count -lt 30 ]; do
    sleep 1
    ((wait_count++))
  done

  # Run hook right before enabling services (user setup complete, runtime dir ready)
  run_hook "$hook"

  # Create log file that the user can write to
  local user_log="$home_dir/podmgr-compose.log"
  touch "$user_log"
  chown "$user:$user" "$user_log"
  chmod 644 "$user_log"
  
  # Also create system log
  local sys_log="/var/log/podmgr.log"
  touch "$sys_log"
  chmod 666 "$sys_log"

  # Log setup state for debugging
  echo "=== podmgr setup debug $(date) ===" >> "$sys_log"
  echo "User: $user, UID: $uid_num" >> "$sys_log"
  echo "Home: $home_dir, Compose: $compose_dir" >> "$sys_log"
  echo "User log file: $user_log" >> "$sys_log"
  echo "Runtime dir: /run/user/$uid_num exists: $(test -d /run/user/$uid_num && echo yes || echo no)" >> "$sys_log"
  echo "Service unit file: $home_dir/.config/systemd/user/$service_name" >> "$sys_log"
  echo "--- Service unit contents ---" >> "$sys_log"
  cat "$home_dir/.config/systemd/user/$service_name" >> "$sys_log" 2>&1 || echo "FAILED TO READ SERVICE FILE" >> "$sys_log"
  echo "--- End service unit ---" >> "$sys_log"
  
  echo "=== daemon-reload ===" >> "$sys_log"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user daemon-reload" >> "$sys_log" 2>&1
  local reload_exit=$?
  echo "daemon-reload exit code: $reload_exit" >> "$sys_log"

  # Debug: check podman state before enabling service
  echo "=== Podman state before service start ===" >> "$sys_log"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && podman info 2>&1 | head -50" >> "$sys_log" 2>&1 || true
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && podman network ls" >> "$sys_log" 2>&1 || true

  # Enable and start service with VERBOSE logging
  echo "=== systemctl --user enable --now $service_name ===" >> "$sys_log"
  echo "Running: sudo -u $user -H bash -c \"cd '$home_dir' && source '$env_file' && systemctl --user enable --now '$service_name'\"" >> "$sys_log"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && set -x && systemctl --user enable --now '$service_name' 2>&1" >> "$sys_log" 2>&1
  local enable_exit=$?
  echo "enable --now exit code: $enable_exit" >> "$sys_log"
  
  # Check if service is actually running
  echo "=== Immediate service check ===" >> "$sys_log"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user is-active '$service_name'" >> "$sys_log" 2>&1
  echo "is-active exit code: $?" >> "$sys_log"
  
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user enable --now podman.socket" >> "$sys_log" 2>&1 || true

  # Debug: check service status after enabling
  echo "=== Service status after enable ===" >> "$sys_log"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user status '$service_name' --no-pager -l" >> "$sys_log" 2>&1 || true
  
  # Check journalctl for the service
  echo "=== journalctl for $service_name ===" >> "$sys_log"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && journalctl --user -u '$service_name' --no-pager -n 50" >> "$sys_log" 2>&1 || true
  
  # Check if the user log file was written to
  echo "=== User log file check ===" >> "$sys_log"
  echo "User log exists: $(test -f "$user_log" && echo yes || echo no)" >> "$sys_log"
  echo "User log size: $(stat -c%s "$user_log" 2>/dev/null || echo 0)" >> "$sys_log"
  if [ -f "$user_log" ] && [ -s "$user_log" ]; then
    echo "--- User log contents ---" >> "$sys_log"
    cat "$user_log" >> "$sys_log" 2>&1
    echo "--- End user log ---" >> "$sys_log"
  fi
  
  echo "=== End podmgr setup debug ===" >> "$sys_log"

  echo "Created user $user"
  echo "Debug logs: $sys_log and $user_log"
}

do_cleanup() {
  local user="$1" compose_dir="$2"
  local home_dir="/var/lib/$user"
  local service_name="$user.service"

  if ! id "$user" >/dev/null 2>&1; then
    echo "User $user does not exist"
    return 0
  fi

  local uid_num=$(id -u "$user" 2>/dev/null)
  local env_file=$(get_user_env "$user")

  # Stop and disable user services
  if [ -n "$uid_num" ] && [ -d "/run/user/$uid_num" ]; then
    sudo -u "$user" -H bash -c "
      cd '$home_dir'
      source '$env_file'
      # Stop compose first
      cd '$compose_dir' 2>/dev/null && podman-compose down --remove-orphans 2>/dev/null || true
      # Disable services
      systemctl --user disable --now '$service_name' 2>/dev/null || true
      systemctl --user disable --now podman.socket 2>/dev/null || true
      # NUKE ALL PODMAN DATA
      podman stop -a -t 0 2>/dev/null || true
      podman rm -a -f 2>/dev/null || true
      podman network prune -f 2>/dev/null || true
      podman volume prune -f 2>/dev/null || true
      podman image prune -a -f 2>/dev/null || true
      podman system reset -f 2>/dev/null || true
    " 2>/dev/null || true
  fi

  loginctl disable-linger "$user" 2>/dev/null || true

  # Kill any remaining user processes
  [ -n "$uid_num" ] && pkill -9 -u "$uid_num" 2>/dev/null || true

  [ -n "$uid_num" ] && {
    systemctl stop "user@$uid_num.service" 2>/dev/null || true
    systemctl stop "user-runtime-dir@$uid_num.service" 2>/dev/null || true
  }

  # Remove subuid/subgid entries
  [ -f /etc/subuid ] && sed -i "/^$user:/d" /etc/subuid
  [ -f /etc/subgid ] && sed -i "/^$user:/d" /etc/subgid

  # OBLITERATE compose directory
  [ -d "$compose_dir" ] && rm -rf "$compose_dir"

  # Delete user (also removes home)
  userdel -r "$user" 2>/dev/null || true

  # OBLITERATE any remaining home directory
  [ -d "$home_dir" ] && rm -rf "$home_dir"

  # OBLITERATE runtime directory
  [ -n "$uid_num" ] && [ -d "/run/user/$uid_num" ] && rm -rf "/run/user/$uid_num"

  # OBLITERATE any podman storage that might be elsewhere
  rm -rf "/tmp/podman-run-$uid_num" 2>/dev/null || true
  rm -rf "/tmp/containers-user-$uid_num" 2>/dev/null || true
  rm -rf "/var/tmp/containers-user-$uid_num" 2>/dev/null || true

  echo "Removed $user and ALL associated data"
}

do_reinstall() {
  local user="$1" compose_dir="$2" hook="$3"
  do_cleanup "$user" "$compose_dir"
  do_setup "$user" "$compose_dir" "$hook"
  echo "Reinstalled $user"
}

do_up() {
  local user="$1"
  run_as_user "$user" "podman-compose up -d"
}

do_down() {
  local user="$1"
  run_as_user "$user" "podman-compose down"
}

do_kill() {
  local user="$1"
  local env_file=$(get_user_env "$user")
  local service_name="$user.service"
  local home_dir="/var/lib/$user"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user stop '$service_name'" 2>/dev/null || true
  echo "Stopped $user"
}

do_ps() {
  local user="$1"
  run_as_user "$user" "podman ps"
}

do_journal() {
  local user="$1"
  local uid_num=$(id -u "$user" 2>/dev/null)
  journalctl "_UID=$uid_num" -f
}

do_exec() {
  local user="$1"
  local compose_dir="${COMPOSE_DIR:-/opt/compose/$user}"
  local env_file=$(get_user_env "$user")
  local home_dir="/var/lib/$user"
  
  # Get first running container name for this user
  local container_name=$(sudo -u "$user" -H bash -c "
    cd '$home_dir'
    source '$env_file'
    podman ps --format '{{.Names}}' | head -1
  " 2>/dev/null)
  
  if [ -z "$container_name" ]; then
    echo "Error: No running containers found for user $user"
    exit 1
  fi
  
  sudo -u "$user" -H bash -c "
    cd '$home_dir'
    source '$env_file'
    cd '$compose_dir'
    podman exec -it '$container_name' bash
  "
}

do_lazydocker() {
  local user="$1"
  local env_file=$(get_user_env "$user")
  local home_dir="/var/lib/$user"
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && lazydocker"
}

USER=""
COMPOSE_DIR=""
HOOK=""
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    setup|cleanup|reinstall|up|down|kill|ps|journal|exec|lazydocker) CMD="$1"; shift ;;
    --user|-u) USER="$2"; shift 2 ;;
    --compose-dir|-c) COMPOSE_DIR="$2"; shift 2 ;;
    --hook) HOOK="$2"; shift 2 ;;
    -h|--help) show_usage ;;
    *)
      if [ -n "$CMD" ] && [ -z "$USER" ]; then
        USER="$1"; shift
      else
        shift
      fi
      ;;
  esac
done

[ -z "$CMD" ] && show_usage
[ -z "$USER" ] && { echo "Error: --user required"; exit 1; }
[ -z "$COMPOSE_DIR" ] && COMPOSE_DIR="/opt/compose/$USER"

case "$CMD" in
  setup) do_setup "$USER" "$COMPOSE_DIR" "$HOOK" ;;
  cleanup) do_cleanup "$USER" "$COMPOSE_DIR" ;;
  reinstall) do_reinstall "$USER" "$COMPOSE_DIR" "$HOOK" ;;
  up) do_up "$USER" ;;
  down) do_down "$USER" ;;
  kill) do_kill "$USER" ;;
  ps) do_ps "$USER" ;;
  journal) do_journal "$USER" ;;
  exec) do_exec "$USER" ;;
  lazydocker) do_lazydocker "$USER" ;;
esac

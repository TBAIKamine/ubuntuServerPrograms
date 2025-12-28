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

  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user daemon-reload" 2>/dev/null || true
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user enable --now '$service_name'" 2>/dev/null || true
  sudo -u "$user" -H bash -c "cd '$home_dir' && source '$env_file' && systemctl --user enable --now podman.socket" 2>/dev/null || true

  echo "Created user $user"
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
  if [ -n "$uid_num" ] && [ -d "/run/user/$uid_num" ]; then
    sudo -u "$user" -H bash -c "
      cd '$home_dir'
      source '$env_file'
      systemctl --user disable --now '$service_name'
      systemctl --user disable --now podman.socket
    " 2>/dev/null || true
  fi

  loginctl disable-linger "$user" 2>/dev/null || true

  [ -n "$uid_num" ] && {
    sudo systemctl stop "user@$uid_num.service" 2>/dev/null || true
    sudo systemctl stop "user-runtime-dir@$uid_num.service" 2>/dev/null || true
  }

  [ -f /etc/subuid ] && sed -i "/^$user:/d" /etc/subuid
  [ -f /etc/subgid ] && sed -i "/^$user:/d" /etc/subgid

  [ -d "$compose_dir" ] && rm -rf "$compose_dir"

  userdel -r "$user" 2>/dev/null || true
  [ -d "$home_dir" ] && rm -rf "$home_dir"
  [ -n "$uid_num" ] && [ -d "/run/user/$uid_num" ] && rm -rf "/run/user/$uid_num"

  echo "Removed $user"
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

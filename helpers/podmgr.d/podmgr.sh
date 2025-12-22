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
    source "$hook"
  elif declare -f "$hook" >/dev/null 2>&1; then
    "$hook"
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
  sudo -u "$user" -H bash -c "source '$env_file' && cd '$compose_dir' && $*"
}

do_setup() {
  local user="$1" compose_dir="$2" pre_hook="$3" post_hook="$4"
  local home_dir="/var/lib/$user"
  local service_name="$user.service"

  id "$user" >/dev/null 2>&1 || useradd -r -d "$home_dir" -s /usr/sbin/nologin "$user"
  local uid_num=$(id -u "$user")

  mkdir -p "$home_dir/.config/systemd/user" "$home_dir/.config/environment.d" "$home_dir/.local/share"

  local env_file="$home_dir/.config/environment.d/podman.conf"
  cat > "$env_file" <<EOF
export XDG_RUNTIME_DIR="/run/user/$uid_num"
export DOCKER_HOST="unix:///run/user/$uid_num/podman/podman.sock"
EOF
  chown -R "$user:$user" "$home_dir"

  loginctl enable-linger "$user" 2>/dev/null || true

  run_hook "$pre_hook"

  local subid_range=$(fsubid)
  grep -q "^$user:" /etc/subuid 2>/dev/null || usermod --add-subuids "$subid_range" "$user"
  grep -q "^$user:" /etc/subgid 2>/dev/null || usermod --add-subgids "$subid_range" "$user"
  sudo -u "$user" -H bash -c "podman system migrate" 2>/dev/null || true

  run_hook "$post_hook"

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

  sudo -u "$user" -H bash -c "source '$env_file' && systemctl --user daemon-reload" 2>/dev/null || true
  sudo -u "$user" -H bash -c "source '$env_file' && systemctl --user enable --now '$service_name'" 2>/dev/null || true
  sudo -u "$user" -H bash -c "source '$env_file' && systemctl --user enable --now podman.socket" 2>/dev/null || true

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
      source '$env_file'
      systemctl --user disable --now '$service_name'
      systemctl --user disable --now podman.socket
    " 2>/dev/null || true
  fi

  [ -n "$uid_num" ] && {
    systemctl stop "user@$uid_num.service" 2>/dev/null || true
    systemctl stop "user-runtime-dir@$uid_num.service" 2>/dev/null || true
  }

  loginctl disable-linger "$user" 2>/dev/null || true

  [ -f /etc/subuid ] && sed -i "/^$user:/d" /etc/subuid
  [ -f /etc/subgid ] && sed -i "/^$user:/d" /etc/subgid

  [ -d "$compose_dir" ] && rm -rf "$compose_dir"

  userdel -r "$user" 2>/dev/null || true
  [ -d "$home_dir" ] && rm -rf "$home_dir"
  [ -n "$uid_num" ] && [ -d "/run/user/$uid_num" ] && rm -rf "/run/user/$uid_num"

  echo "Removed $user"
}

do_reinstall() {
  local user="$1" compose_dir="$2" pre_hook="$3" post_hook="$4"
  do_cleanup "$user" "$compose_dir"
  do_setup "$user" "$compose_dir" "$pre_hook" "$post_hook"
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
  sudo -u "$user" -H bash -c "source '$env_file' && systemctl --user stop '$service_name'" 2>/dev/null || true
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
  
  # Get container name from compose file
  local compose_file="$compose_dir/docker-compose.yml"
  [ ! -f "$compose_file" ] && compose_file="$compose_dir/docker-compose.yaml"
  [ ! -f "$compose_file" ] && compose_file="$compose_dir/compose.yml"
  [ ! -f "$compose_file" ] && compose_file="$compose_dir/compose.yaml"
  
  if [ ! -f "$compose_file" ]; then
    echo "Error: No compose file found in $compose_dir"
    exit 1
  fi
  
  local container_name=$(grep -m1 'container_name:' "$compose_file" | sed 's/.*container_name:\s*//' | tr -d '"' | tr -d "'" | xargs)
  
  if [ -z "$container_name" ]; then
    echo "Error: No container_name found in $compose_file"
    exit 1
  fi
  
  local env_file=$(get_user_env "$user")
  sudo -u "$user" -H bash -c "
    source '$env_file'
    cd '$compose_dir'
    podman exec -it '$container_name' bash
  "
}

do_lazydocker() {
  local user="$1"
  local env_file=$(get_user_env "$user")
  sudo -u "$user" -H bash -c "source '$env_file' && cd && lazydocker"
}

USER=""
COMPOSE_DIR=""
PRE_HOOK=""
POST_HOOK=""
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    setup|cleanup|reinstall|up|down|kill|ps|journal|exec|lazydocker) CMD="$1"; shift ;;
    --user|-u) USER="$2"; shift 2 ;;
    --compose-dir|-c) COMPOSE_DIR="$2"; shift 2 ;;
    --pre-hook) PRE_HOOK="$2"; shift 2 ;;
    --post-hook) POST_HOOK="$2"; shift 2 ;;
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
  setup) do_setup "$USER" "$COMPOSE_DIR" "$PRE_HOOK" "$POST_HOOK" ;;
  cleanup) do_cleanup "$USER" "$COMPOSE_DIR" ;;
  reinstall) do_reinstall "$USER" "$COMPOSE_DIR" "$PRE_HOOK" "$POST_HOOK" ;;
  up) do_up "$USER" ;;
  down) do_down "$USER" ;;
  kill) do_kill "$USER" ;;
  ps) do_ps "$USER" ;;
  journal) do_journal "$USER" ;;
  exec) do_exec "$USER" ;;
  lazydocker) do_lazydocker "$USER" ;;
esac

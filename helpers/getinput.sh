#!/usr/bin/env bash
set -euo pipefail
trap 'echo; echo "Interrupted by user. Exiting..."; exit 130' INT

read_line_with_visibility(){
  local prompt_text="$1"
  local default_val="$2"
  local mode="${3-visible}"
  local initial="${4-}"
  local input=""
  local ch rest
  if [ -n "$default_val" ]; then printf "%s: [%s] " "$prompt_text" "$default_val"; else printf "%s: " "$prompt_text"; fi
  if [ "$mode" = "visible" ]; then
    [ -n "$initial" ] && printf "%s" "$initial"
    IFS= read -r rest || true
    input="$initial$rest"
    [ -z "$input" ] && { printf "%s\n" "$default_val"; echo; return 0; } || { printf "%s\n" "$input"; echo "$input"; return 0; }
  fi
  input="$initial"
  [ -n "$initial" ] && [ "$mode" = "dotted" ] && printf "*" || true
  while true; do
    IFS= read -rsn1 ch || true
    [ "$ch" = $'\x03' ] && { echo; exit 130; }
    if [ "$ch" = $'\n' ] || [ "$ch" = $'\r' ]; then
      printf "\n"
      [ -z "$input" ] && { printf "%s\n" "$default_val"; echo; return 0; } || { printf "%s\n" "$input"; echo "$input"; return 0; }
    fi
    if [ "$ch" = $'\e' ]; then read -rsn2 -t 0.01 rest 2>/dev/null || true; continue; fi
    if [ "$ch" = $'\x7f' ] || [ "$ch" = $'\b' ]; then
      if [ -n "$input" ]; then input=${input%?}; [ "$mode" = "dotted" ] && printf "\b \b" || true; fi
      continue
    fi
    input+="$ch"
    [ "$mode" = "dotted" ] && printf "*" || true
  done
}

getInput(){
  local prompt_text="$1"
  local default_val="${2-}"
  local timeout_sec="${3-10}"
  local visibility_mode="${4-visible}"
  local seconds header key rest input
  header="$prompt_text"
  [ -n "$default_val" ] && header+=" [$default_val]"
  printf "%s\n" "$header"
  seconds=$((timeout_sec))
  while [ $seconds -ge 0 ]; do
    printf "\r\033[Kmoving on in %ds" "$seconds"
    if read -rsn1 -t 1 key 2>/dev/null; then
      case "$key" in
        $'\x03') echo; exit 130 ;;
        $'\n'|$'\r'|$' ') printf "\r\033[K"; printf "%s\n" "${default_val}"; echo "${default_val}"; return 0 ;;
        $'\e') read -rsn2 -t 0.01 rest 2>/dev/null || true; printf "\r\033[K"; read_line_with_visibility "$prompt_text" "$default_val" "$visibility_mode"; return 0 ;;
        *) printf "\r\033[K"; read_line_with_visibility "$prompt_text" "$default_val" "$visibility_mode" "$key"; return 0 ;;
      esac
    fi
    seconds=$((seconds - 1))
    if [ $seconds -lt 0 ]; then printf "\r\033[K"; printf "%s\n" "$default_val"; echo "$default_val"; return 0; fi
  done
}
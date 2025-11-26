#!/usr/bin/env bash
set -euo pipefail
trap 'echo; echo "Interrupted by user. Exiting..."; exit 130' INT

read_line_with_visibility(){
  local prompt_text="$1"
  local default_val="$2"
  local mode="${3-visible}"
  local initial="${4-}"
  local show_prompt="${5-true}"
  local input="$initial"
  local ch rest

  if [ "$show_prompt" = "true" ]; then
    if [ -n "$default_val" ]; then
      printf "%s: [%s] " "$prompt_text" "$default_val"
    else
      printf "%s: " "$prompt_text"
    fi
  fi

  if [ -n "$initial" ]; then
    if [ "$mode" = "dotted" ]; then
      printf "%${#initial}s" "" | tr ' ' '*'
    else
      printf "%s" "$initial"
    fi
  fi

  while true; do
    IFS= read -rsN1 ch || true
    case "$ch" in
      $'\x03')
        printf "\n"
        exit 130
        ;;
      $'\n'|$'\r')
        printf "\n"
        if [ -z "$input" ]; then
          printf "%s\n" "$default_val"
          echo "$default_val"
        else
          printf "%s\n" "$input"
          echo "$input"
        fi
        return 0
        ;;
      $'\x7f'|$'\b')
        if [ -n "$input" ]; then
          input=${input%?}
          printf "\b \b"
        fi
        ;;
      $'\e')
        read -rsn2 -t 0.01 rest 2>/dev/null || true
        ;;
      '')
        ;;
      *)
        input+="$ch"
        if [ "$mode" = "dotted" ]; then
          printf "*"
        else
          printf "%s" "$ch"
        fi
        ;;
    esac
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
        $'\x03') printf "\n"; exit 130 ;;
        $'\n'|$'\r'|$' ') printf "\r\033[K"; printf "%s\n" "${default_val}"; echo "${default_val}"; return 0 ;;
        $'\e') read -rsn2 -t 0.01 rest 2>/dev/null || true; printf "\r\033[K"; read_line_with_visibility "$prompt_text" "$default_val" "$visibility_mode" "" "false"; return 0 ;;
        *) printf "\r\033[K"; read_line_with_visibility "$prompt_text" "$default_val" "$visibility_mode" "$key" "false"; return 0 ;;
      esac
    fi
    seconds=$((seconds - 1))
  done
  printf "\r\033[K"
  printf "%s\n" "$default_val"
  echo "$default_val"
}
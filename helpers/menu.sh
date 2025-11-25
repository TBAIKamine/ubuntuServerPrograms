#!/bin/bash

# Universal Ubuntu Server OS Provisioning Script
# Works on TTY1, Warp, SSH, and any terminal environment

# Initialize selection states
declare -A OPTIONS=(
    ["passwordless_sudoer"]="1"
    ["fail2ban_vpn_bypass"]="1"
    ["sharkvpn"]="1"
    ["webserver"]="1"
    ["apache_domains"]="1"
    ["certbot"]="1"
    ["phpmyadmin"]="1"
    ["roundcube"]="1"
    ["wp_cli"]="1"
    ["pyenv_python"]="1"
    ["podman"]="1"
    ["lazydocker"]="1"
    ["portainer"]="1"
    ["gitea"]="1"
    ["gitea_runner"]="0"
    ["docker_mailserver"]="1"
    ["n8n"]="1"
    ["selenium"]="0"
    ["homeassistant"]="0"
    ["grafana_otel"]="0"
)

declare -A FORCED_OPTIONS=()
declare -A DEPENDENCIES=(
    ["certbot"]="pyenv_python"
    ["apache_domains"]="webserver"
    ["phpmyadmin"]="webserver"
    ["roundcube"]="webserver"
    ["lazydocker"]="podman"
    ["portainer"]="podman"
    ["gitea"]="podman"
    ["gitea_runner"]="podman"
    ["docker_mailserver"]="podman"
    ["n8n"]="podman"
    ["selenium"]="podman"
    ["homeassistant"]="podman"
    ["grafana_otel"]="podman"
)

declare -A DESCRIPTIONS=(
    ["passwordless_sudoer"]="Passwordless sudoer with secret"
    ["fail2ban_vpn_bypass"]="Fail2ban with VPN bypass for incoming traffic"
    ["sharkvpn"]="SharkVPN client"
    ["webserver"]="Web server setup"
    ["apache_domains"]="Apache domains manager"
    ["certbot"]="Certbot SSL certificates (requires pyenv)"
    ["phpmyadmin"]="phpMyAdmin web interface"
    ["roundcube"]="Roundcube webmail"
    ["wp_cli"]="WordPress CLI tool"
    ["pyenv_python"]="PyEnv with global Python 3.13"
    ["podman"]="Podman container runtime"
    ["lazydocker"]="LazyDocker container management UI"
    ["portainer"]="Portainer container management"
    ["gitea"]="Gitea Git service"
    ["gitea_runner"]="Gitea Act Runner (dual user setup)"
    ["docker_mailserver"]="Docker Mailserver"
    ["n8n"]="n8n workflow automation"
    ["selenium"]="Selenium testing framework"
    ["homeassistant"]="Home Assistant automation"
    ["grafana_otel"]="Grafana with OpenTelemetry LGTM stack"
)

# Define explicit order to match the hardcoded sequence above
OPTION_KEYS=(
    "passwordless_sudoer"
    "fail2ban_vpn_bypass"
    "sharkvpn"
    "webserver"
    "apache_domains"
    "certbot"
    "phpmyadmin"
    "roundcube"
    "wp_cli"
    "pyenv_python"
    "podman"
    "lazydocker"
    "portainer"
    "gitea"
    "gitea_runner"
    "docker_mailserver"
    "n8n"
    "selenium"
    "homeassistant"
    "grafana_otel"
)
CURRENT_SELECTION=0
USE_FANCY=0
TIMER_ACTIVE=1
COUNTDOWN=10
INTERACTION_DETECTED=0
IDLE_START=0
# Detect terminal capabilities - be more conservative
detect_capabilities() {
    USE_FANCY=0
    
    # Only enable fancy mode for known good terminals
    if [ -t 0 ] && [ -t 1 ]; then
        case "$TERM" in
            xterm*|screen*|tmux*|*color*)
                # Test if arrow keys work by checking terminal database
                if command -v tput >/dev/null 2>&1; then
                    if tput cuu1 >/dev/null 2>&1 && tput cud1 >/dev/null 2>&1; then
                        USE_FANCY=1
                    fi
                fi
                ;;
        esac
    fi
    
    # Special detection for Warp (often has TERM_PROGRAM set)
    if [ "$TERM_PROGRAM" = "WarpTerminal" ] || [ -n "$WARP_IS_LOCAL_SHELL_SESSION" ]; then
        USE_FANCY=1
    fi
}

# Color setup
setup_colors() {
    if [ "$USE_FANCY" -eq 1 ] && command -v tput >/dev/null 2>&1; then
        GRAY=$(tput setaf 8 2>/dev/null || printf '\033[90m')
        RESET=$(tput sgr0 2>/dev/null || printf '\033[0m')
        HIDE_CURSOR=$(tput civis 2>/dev/null || printf '\033[?25l')
        SHOW_CURSOR=$(tput cnorm 2>/dev/null || printf '\033[?25h')
    else
        GRAY=""
        RESET=""
        HIDE_CURSOR=""
        SHOW_CURSOR=""
    fi
}

# Timer management functions
start_idle_timer() {
    IDLE_START=$(date +%s)
}

check_idle_timeout() {
    if [ "$INTERACTION_DETECTED" -eq 1 ]; then
        local current_time=$(date +%s)
        local idle_duration=$((current_time - IDLE_START))
        if [ "$idle_duration" -ge 60 ]; then  # 60 seconds idle timeout
            TIMER_ACTIVE=1
            COUNTDOWN=10
            INTERACTION_DETECTED=0
        fi
    fi
}

# Dependency management
update_dependencies() {
    # Clear forced options
    FORCED_OPTIONS=()
    
    # Build list of options that should be forced
    local temp_forced=()
    
    # When child is selected, auto-select its parent (dependency)
    for child in "${!DEPENDENCIES[@]}"; do
        if [ "${OPTIONS[$child]}" = "1" ]; then
            local parent="${DEPENDENCIES[$child]}"
            OPTIONS["$parent"]="1"
            temp_forced["$parent"]="1"
        fi
    done
    
    # When parent is deselected, auto-deselect children
    for child in "${!DEPENDENCIES[@]}"; do
        local parent="${DEPENDENCIES[$child]}"
        if [ "${OPTIONS[$parent]}" = "0" ]; then
            local has_other_reason=0
            # Check if this child has other dependencies that are satisfied
            for other_child in "${!DEPENDENCIES[@]}"; do
                if [ "$other_child" != "$child" ] && [ "${DEPENDENCIES[$other_child]}" = "$parent" ]; then
                    if [ "${OPTIONS[$other_child]}" = "1" ]; then
                        has_other_reason=1
                        break
                    fi
                fi
            done
            
            if [ "$has_other_reason" = "0" ]; then
                OPTIONS["$child"]="0"
            fi
        fi
    done
    
    # Mark dependencies as forced (grayed out)
    for child in "${!DEPENDENCIES[@]}"; do
        if [ "${OPTIONS[$child]}" = "1" ]; then
            local parent="${DEPENDENCIES[$child]}"
            temp_forced["$parent"]="1"
            FORCED_OPTIONS["$parent"]="1"
        fi
    done
}

is_option_forced() {
    [ "${FORCED_OPTIONS[$1]}" = "1" ]
}

toggle_option() {
    local option="$1"
    
    if is_option_forced "$option"; then
        return 1
    fi
    
    if [ "${OPTIONS[$option]}" = "1" ]; then
        OPTIONS["$option"]="0"
    else
        OPTIONS["$option"]="1"
    fi
    
    update_dependencies
    return 0
}

# Fancy menu with proper box drawing
draw_fancy_menu() {
    update_dependencies
    clear
    
    echo "╔══════════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                            Ubuntu Server OS Provisioning Setup                               ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════════════════════╣"
    
    if [ "$TIMER_ACTIVE" -eq 1 ]; then
        printf "║ Auto-continue in: %2d seconds | Use ↑↓ arrows, SPACE to toggle, ENTER to continue, Q to quit  ║\n" "$COUNTDOWN"
    else
        echo "║ Use ↑↓ arrows to navigate, SPACE to toggle, ENTER to continue, Q to quit                    ║"
    fi
    
    echo "╠══════════════════════════════════════════════════════════════════════════════════════════════╣"
    echo "║ Note: Grayed options are auto-selected due to dependencies                                   ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════════════════════╣"
    
    local index=0
    for key in "${OPTION_KEYS[@]}"; do
        local status="[ ]"
        local marker="   "
        local description="${DESCRIPTIONS[$key]}"
        
        if [ "${OPTIONS[$key]}" = "1" ]; then
            status="[✓]"
        fi
        
        if [ "$index" -eq "$CURRENT_SELECTION" ]; then
            marker="►  "
        fi
        
        # Build the line differently based on whether option is forced
        if is_option_forced "$key"; then
            status="[✓]"
            # For grayed options, manually calculate padding (total width should be 84 chars)
            local desc_len=${#description}
            local padding=$((84 - desc_len))
            local spaces=$(printf '%*s' "$padding" '')
            printf "║ %s %s %s%s%s%s ║\n" "$marker" "$status" "$GRAY" "$description" "$RESET" "$spaces"
        else
            # Normal display without color codes (84 chars for description area)
            printf "║ %s %s %-84s ║\n" "$marker" "$status" "$description"
        fi
        
        ((index++))
    done
    
    echo "╚══════════════════════════════════════════════════════════════════════════════════════════════╝"
}

# Simple menu fallback
draw_simple_menu() {
    update_dependencies
    clear
    
    echo "================================================================================"
    echo "                Ubuntu Server OS Provisioning Setup"
    echo "================================================================================"
    echo "Navigation: Use numbers to toggle, ENTER to continue, Q to quit"
    echo "Note: Options marked with (*) are auto-selected due to dependencies"
    echo "================================================================================"
    
    local index=1
    for key in "${OPTION_KEYS[@]}"; do
        local status="[ ]"
        local marker=""
        
        if [ "${OPTIONS[$key]}" = "1" ]; then
            status="[X]"
        fi
        
        if is_option_forced "$key"; then
            status="[X]"
            marker=" (*)"
        fi
        
        printf "%2d. %s %-60s%s\n" "$index" "$status" "${DESCRIPTIONS[$key]}" "$marker"
        ((index++))
    done
    
    echo "================================================================================"
}

# Enhanced input handling with proper timer functionality
handle_fancy_input() {
    local orig_stty=$(stty -g 2>/dev/null || echo "")
    
    # Use timeout-based reading for timer functionality
    stty -echo -icanon min 0 time 0 2>/dev/null || return 1
    
    printf "%s" "$HIDE_CURSOR"
    
    local last_countdown_update=$(date +%s)
    
    while true; do
        local key_code=""
        local char=""
        
        # Check if input is available with short timeout (0.1 seconds)
        if IFS= read -r -t0.1 -n1 -d '' char 2>/dev/null; then
            # Convert to ASCII code properly
            if [ -z "$char" ]; then
                # Empty read likely means Enter/newline was pressed
                key_code="10"
            else
                key_code=$(printf '%s' "$char" | od -An -td1 | tr -d ' \n')
            fi
            
            # Input received - disable timer and start idle tracking
            if [ "$TIMER_ACTIVE" -eq 1 ]; then
                TIMER_ACTIVE=0
                INTERACTION_DETECTED=1
                start_idle_timer
            elif [ "$INTERACTION_DETECTED" -eq 1 ]; then
                start_idle_timer  # Reset idle timer on each interaction
            fi
            
            # Handle keys by their actual ASCII codes
            case "$key_code" in
                10|13)  # Enter key
                    break
                    ;;
                32)  # Space key
                    current_key="${OPTION_KEYS[$CURRENT_SELECTION]}"
                    if toggle_option "$current_key"; then
                        draw_fancy_menu
                    else
                        # Visual feedback for forced options
                        clear
                        echo "╔═══════════════════════════════════════════════════════════════════════════════════════════════╗"
                        echo "║                                      NOTICE                                                   ║"
                        echo "╠═══════════════════════════════════════════════════════════════════════════════════════════════╣"
                        echo "║ Cannot toggle: ${DESCRIPTIONS[$current_key]}"
                        echo "║ This option is auto-selected because another selected option depends on it."
                        echo "║ Press any key to continue..."
                        echo "╚═══════════════════════════════════════════════════════════════════════════════════════════════╝"
                        read -r -n1 -t5 2>/dev/null  # Wait for any key with timeout
                        draw_fancy_menu
                    fi
                    ;;
                27)  # Escape - check for arrow keys
                    local seq=""
                    if read -r -n2 -t0.1 seq 2>/dev/null; then
                        case "$seq" in
                            "[A")  # Up arrow
                                ((CURRENT_SELECTION--))
                                if [ "$CURRENT_SELECTION" -lt 0 ]; then
                                    CURRENT_SELECTION=$((${#OPTION_KEYS[@]} - 1))
                                fi
                                draw_fancy_menu
                                ;;
                            "[B")  # Down arrow
                                ((CURRENT_SELECTION++))
                                if [ "$CURRENT_SELECTION" -ge "${#OPTION_KEYS[@]}" ]; then
                                    CURRENT_SELECTION=0
                                fi
                                draw_fancy_menu
                                ;;
                        esac
                    fi
                    ;;
                113|81)  # 'q' or 'Q'
                    printf "%s" "$SHOW_CURSOR"
                    [ -n "$orig_stty" ] && stty "$orig_stty" 2>/dev/null || stty sane 2>/dev/null
                    echo -e "\nSetup cancelled."
                    exit 0
                    ;;
            esac
        else
            # No input received - handle timer
            local current_time=$(date +%s)
            if [ "$TIMER_ACTIVE" -eq 1 ]; then
                # Check if a second has passed since last countdown update
                if [ $((current_time - last_countdown_update)) -ge 1 ]; then
                    ((COUNTDOWN--))
                    last_countdown_update=$current_time
                    if [ "$COUNTDOWN" -le 0 ]; then
                        break
                    fi
                    draw_fancy_menu
                fi
            else
                # Check for idle timeout when timer is not active
                check_idle_timeout
                if [ "$TIMER_ACTIVE" -eq 1 ]; then
                    last_countdown_update=$current_time
                    draw_fancy_menu
                fi
            fi
        fi
    done
    
    printf "%s" "$SHOW_CURSOR"
    [ -n "$orig_stty" ] && stty "$orig_stty" 2>/dev/null || stty sane 2>/dev/null
}

handle_simple_input() {
    while true; do
        echo -n "Enter choice (1-${#OPTION_KEYS[@]}, ENTER to continue, Q to quit): "
        read -r choice
        
        case "$choice" in
            ""|"c"|"C")
                return 0
                ;;
            "q"|"Q")
                echo "Setup cancelled."
                exit 0
                ;;
            [1-9]|[1-9][0-9])
                if [ "$choice" -ge 1 ] && [ "$choice" -le "${#OPTION_KEYS[@]}" ]; then
                    local key="${OPTION_KEYS[$((choice-1))]}"
                    if toggle_option "$key"; then
                        draw_simple_menu
                        echo "Toggled: ${DESCRIPTIONS[$key]}"
                    else
                        echo "Cannot toggle: ${DESCRIPTIONS[$key]} (auto-selected)"
                    fi
                else
                    echo "Invalid choice: $choice"
                fi
                ;;
            *)
                echo "Invalid input. Try again."
                ;;
        esac
    done
}

# Cleanup function
cleanup() {
    printf "%s" "$SHOW_CURSOR"
    stty sane 2>/dev/null || true
    echo ""
}

trap cleanup EXIT INT TERM

# Main function
main() {
    detect_capabilities
    setup_colors
    update_dependencies
    
    if [ "$USE_FANCY" -eq 1 ]; then
        echo "Using enhanced interface..."
        sleep 0.5
        draw_fancy_menu
        if ! handle_fancy_input; then
            echo -e "\nFalling back to simple interface..."
            sleep 1
            USE_FANCY=0
        fi
    fi
    
    
    if [ "$USE_FANCY" -eq 0 ]; then
        draw_simple_menu
        handle_simple_input
    fi
    
    echo -e "\nProceeding with selected options...\n"
    
    echo "Selected options:"
    for key in "${OPTION_KEYS[@]}"; do
        if [ "${OPTIONS[$key]}" = "1" ]; then
            echo "  ✓ ${DESCRIPTIONS[$key]}"
        fi
    done
    echo ""
    
    # Export OPTIONS array for parent script to use
    # Note: Bash associative arrays can't be exported directly
    # So we'll write them to a temporary file or use declare -p
    for key in "${!OPTIONS[@]}"; do
        declare -g "OPTION_${key}=${OPTIONS[$key]}"
        export "OPTION_${key}"
    done
}

# Only run main if script is executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
fi
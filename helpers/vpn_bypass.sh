#!/bin/bash
echo "Setting up VPN bypass and security configurations..."
ABS_PATH=$(dirname "$(realpath "$0")")

# Non-interactive guard: the orchestrator must provide these values.
if [ -z "${YOUR_INTERFACE:-}" ] || \
   [ -z "${YOUR_LAN_SUBNET:-}" ] || \
   [ -z "${YOUR_DEFAULT_GATEWAY:-}" ] || \
   [ -z "${YOUR_PUBLIC_IP:-}" ]; then
    exit 200
fi


export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
apt install fail2ban iptables-persistent -y

# Don't clobber existing local config on reruns.
if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# Enable sshd jail if not already present.
grep -q '^\[sshd\]$' /etc/fail2ban/jail.local || echo -e '\n[sshd]\nenabled = true\n' >> /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl start fail2ban

ensure_iptables_rule() {
    # usage: ensure_iptables_rule <table> <chain> <rule...>
    local table="$1"; shift
    local chain="$1"; shift
    if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
        return 0
    fi
    iptables -t "$table" -A "$chain" "$@"
}

ensure_iptables_rule filter INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ensure_iptables_rule filter INPUT -i lo -j ACCEPT
ensure_iptables_rule filter INPUT -p tcp --dport 22 -j ACCEPT

# Determine what ports to open based on what's actually installed.
if dpkg -s apache2 &>/dev/null; then
    ensure_iptables_rule filter INPUT -p tcp --dport 80 -j ACCEPT
    ensure_iptables_rule filter INPUT -p tcp --dport 443 -j ACCEPT
fi

if [ -f "/opt/compose/docker-mailserver/compose.yaml" ]; then
    ensure_iptables_rule filter INPUT -p tcp --dport 25 -j ACCEPT
    ensure_iptables_rule filter INPUT -p tcp --dport 587 -j ACCEPT
    ensure_iptables_rule filter INPUT -p tcp --dport 993 -j ACCEPT
    ensure_iptables_rule filter INPUT -p tcp --dport 995 -j ACCEPT
    ensure_iptables_rule nat PREROUTING -p tcp --dport 25 -j REDIRECT --to-port 1025
    ensure_iptables_rule nat PREROUTING -p tcp --dport 587 -j REDIRECT --to-port 1587
    ensure_iptables_rule nat PREROUTING -p tcp --dport 993 -j REDIRECT --to-port 1993
    ensure_iptables_rule nat PREROUTING -p tcp --dport 995 -j REDIRECT --to-port 1995
fi
netfilter-persistent save

escape_sed_repl() {
    # Escape replacement string for sed (delimiter |) and & special char.
    printf '%s' "$1" | sed -e 's/[\\&|]/\\\\&/g'
}

tmpl="$ABS_PATH/setup_vpn_bypass.sh"
dest="/usr/local/bin/setup_vpn_bypass.sh"

if [ ! -f "$tmpl" ]; then
    echo "Error: setup_vpn_bypass.sh template not found: $tmpl" >&2
    exit 1
fi

iface_esc=$(escape_sed_repl "$YOUR_INTERFACE")
lan_esc=$(escape_sed_repl "$YOUR_LAN_SUBNET")
gw_esc=$(escape_sed_repl "$YOUR_DEFAULT_GATEWAY")
ip_esc=$(escape_sed_repl "$YOUR_PUBLIC_IP")

tmpfile=$(mktemp)
sed \
    -e "s|^YOUR_INTERFACE=\".*\"|YOUR_INTERFACE=\"$iface_esc\"|" \
    -e "s|^YOUR_LAN_SUBNET=\".*\"|YOUR_LAN_SUBNET=\"$lan_esc\"|" \
    -e "s|^YOUR_DEFAULT_GATEWAY=\".*\"|YOUR_DEFAULT_GATEWAY=\"$gw_esc\"|" \
    -e "s|^YOUR_PUBLIC_IP=\".*\"|YOUR_PUBLIC_IP=\"$ip_esc\"|" \
    "$tmpl" >"$tmpfile"

install -m 0755 "$tmpfile" "$dest"
rm -f "$tmpfile"

cp $ABS_PATH/vpn-bypass.service /etc/systemd/system/vpn-bypass.service
systemctl daemon-reload
systemctl enable vpn-bypass.service
systemctl start vpn-bypass.service
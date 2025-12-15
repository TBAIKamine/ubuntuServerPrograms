#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
apt install fail2ban iptables-persistent -y
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
grep -q '^[sshd]' /etc/fail2ban/jail.local || echo -e '\n[sshd]\nenabled = true\n' >> /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl start fail2ban
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
if [ "${OPTIONS[webserver]}" = "1" ]; then
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
fi
if [ "${OPTIONS[docker_mailserver]}" = "1" ]; then
    iptables -A INPUT -p tcp --dport 587 -j ACCEPT
    iptables -A INPUT -p tcp --dport 993 -j ACCEPT
    iptables -A INPUT -p tcp --dport 995 -j ACCEPT
    iptables -t nat -A OUTPUT -p tcp --dport 587 -j REDIRECT --to-port 1587
    iptables -t nat -A OUTPUT -p tcp --dport 993 -j REDIRECT --to-port 1993
    iptables -t nat -A OUTPUT -p tcp --dport 995 -j REDIRECT --to-port 1995
fi
netfilter-persistent save
ABS_PATH=$(dirname "$(realpath "$0")")
cp $ABS_PATH/setup_vpn_bypass.sh /usr/local/bin/setup_vpn_bypass.sh
chmod +x /usr/local/bin/setup_vpn_bypass.sh
cp $ABS_PATH/vpn-bypass.service /etc/systemd/system/vpn-bypass.service
systemctl daemon-reload
systemctl enable vpn-bypass.service
systemctl start vpn-bypass.service
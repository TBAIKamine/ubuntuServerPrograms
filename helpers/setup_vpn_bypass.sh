#!/bin/bash

# --- VARIABLES TO CONFIGURE ---
YOUR_INTERFACE=""         # Your physical network interface (e.g., eth0, enp1s0)
YOUR_LAN_SUBNET="" # Your local network subnet
YOUR_DEFAULT_GATEWAY="" # The IP of your router/gateway
YOUR_PUBLIC_IP=""   # The IP address of your Ubuntu server on the LAN
# ------------------------------

# 1. Add entry to /etc/iproute2/rt_tables if it doesn't exist
if ! grep -q "200 vpn_bypass" /etc/iproute2/rt_tables; then
    echo "200       vpn_bypass" | sudo tee -a /etc/iproute2/rt_tables
fi

# 2. Flush (clear) existing rules and routes for the bypass table to avoid duplicates on rerun
# (Using 'vpn_bypass' instead of 'ssh_bypass')
sudo ip rule del to ${YOUR_PUBLIC_IP} iif ${YOUR_INTERFACE} lookup vpn_bypass 2>/dev/null
sudo ip rule del from ${YOUR_PUBLIC_IP} oif ${YOUR_INTERFACE} lookup vpn_bypass 2>/dev/null
sudo ip rule del from ${YOUR_PUBLIC_IP} lookup vpn_bypass priority 100 2>/dev/null
sudo ip route flush table vpn_bypass 2>/dev/null

# 3. Add routes to the new routing table (vpn_bypass)
# These routes define how responses to incoming traffic should go: directly through your physical interface.
sudo ip route replace ${YOUR_LAN_SUBNET} dev ${YOUR_INTERFACE} table vpn_bypass
sudo ip route replace default via ${YOUR_DEFAULT_GATEWAY} dev ${YOUR_INTERFACE} table vpn_bypass

# 4. Create IP rules for Policy-Based Routing

# ➡️ RULE FOR INCOMING TRAFFIC RESPONSES (Response Bypass)
# This rule is the key change. When the server generates a response (outgoing packet) 
# and the source IP is YOUR_PUBLIC_IP, use the 'vpn_bypass' table.
# This ensures responses to any port (SSH, web server, etc.) go back out the physical interface.
sudo ip rule add from ${YOUR_PUBLIC_IP} lookup vpn_bypass priority 100
# ------------------------------
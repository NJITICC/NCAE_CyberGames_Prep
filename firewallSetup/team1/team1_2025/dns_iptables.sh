#!/bin/bash

echo "NJIT NCAE 2025 DNS iptables Script"
echo

# Checks if user is root
if [ "$EUID" -ne 0 ]
    then echo "This script must be ran as root!"
    exit 1
fi

ROUTER="192.168.9.1"
BACKUP="192.168.9.15"
COMP_DNS="172.18.0.12"

# Loads conntrack.
modprobe ip_conntrack

# Allow existing connections and localhost.
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Whitelist output to certain IPs.
iptables -A OUTPUT -d $COMP_DNS -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT

# Reject connections to internal LAN and WAN.
iptables -A OUTPUT -d 172.16.0.0/12 -m conntrack --ctstate NEW,INVALID -j REJECT
iptables -A OUTPUT -d 192.168.0.0/16 -m conntrack --ctstate NEW,INVALID -j REJECT

# Allow services in.
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT

# Default policy.
iptables -P FORWARD DROP
iptables -P INPUT DROP

# Save
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

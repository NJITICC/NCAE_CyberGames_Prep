#!/bin/bash

echo "NJIT NCAE 2025 Database iptables Script"
echo

# Checks if user is root
if [ "$EUID" -ne 0 ]
    then echo "This script must be ran as root!"
    exit 1
fi

ROUTER="192.168.9.1"
BACKUP="192.168.9.15"
COMP_DNS="172.18.0.12"
SQL_PORT="5432"

# Disable firewalld.
systemctl disable --now firewalld.service 2> /dev/null || true

# Loads conntrack.
modprobe ip_conntrack

# Allow existing connections and localhost.
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Whitelist output to certain IPs.
iptables -A OUTPUT -d $COMP_DNS -j ACCEPT

# Reject connections to internal LAN and WAN.
iptables -A OUTPUT -d 172.16.0.0/12 -m conntrack --ctstate NEW,INVALID -j REJECT
iptables -A OUTPUT -d 192.168.0.0/16 -m conntrack --ctstate NEW,INVALID -j REJECT

# Allow services in.
iptables -A INPUT -p tcp --dport $SQL_PORT -j ACCEPT
iptables -A INPUT -s $ROUTER -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -s $BACKUP -p tcp --dport 22 -j ACCEPT

# Default policy.
iptables -P FORWARD DROP
iptables -P INPUT DROP

# Save
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

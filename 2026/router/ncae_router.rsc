# ===============================
# NCAE Router Base ()
# Stable bridge model + jump host logic
# Uses explicit :global teamNum
# ===============================

:delay 5

# ---- Require explicit team number ----
:global teamNum
:if ([:typeof $teamNum] = "nothing") do={
    :error "Set :global teamNum <n> before running"
}

# ---- Interface names ----
:local WANBR "WAN"
:local LANBR "LAN"
:local WANIF "ether1"
:local LANIF "ether2"

# ---- Competition network vars ----
:local compGw "172.18.0.1"
:local compDns "172.18.0.12"
:local compCdn "172.18.13.25"
:local compCa "172.18.0.38"
:local compNet "172.18.0.0/16"
:local compJumphost "172.18.12.15"
:local teamJumphost "172.18.15.1"

# ---- Team addressing ----
:local TEAM $teamNum
:local WANIP ("172.18.13." . $TEAM . "/16")
:local LANIP ("192.168." . $TEAM . ".1/24")
:local LANNET ("192.168." . $TEAM . ".0/24")

:local WEBIP ("192.168." . $TEAM . ".5")
:local DNSIP ("192.168." . $TEAM . ".12")
:local DBIP  ("192.168." . $TEAM . ".7")
:local FTPIP ("172.18.14." . $TEAM)
:local BACKUPIP ("192.168." . $TEAM . ".15")

# ---- Wait for physical interfaces to exist ----
:local tries 0
:while (([:len [/interface find name=$WANIF]] = 0) || ([:len [/interface find name=$LANIF]] = 0)) do={
    :delay 1
    :set tries ($tries + 1)
    :if ($tries > 20) do={
        :log error "Interfaces not ready"
        :error "Interface wait timeout"
    }
}

# ---- Wait until interfaces are running ----
:set tries 0
:while (([/interface get $WANIF running] = false) || ([/interface get $LANIF running] = false)) do={
    :delay 1
    :set tries ($tries + 1)
    :if ($tries > 20) do={
        :log warning "Interfaces not fully running yet; continuing"
        :break
    }
}

# ---- Create bridges if missing ----
:if ([:len [/interface bridge find name=$WANBR]] = 0) do={
    /interface bridge add name=$WANBR
}
:if ([:len [/interface bridge find name=$LANBR]] = 0) do={
    /interface bridge add name=$LANBR
}

# ---- Add bridge ports safely ----
:if ([:len [/interface bridge port find bridge=$WANBR interface=$WANIF]] = 0) do={
    /interface bridge port add bridge=$WANBR interface=$WANIF
}
:if ([:len [/interface bridge port find bridge=$LANBR interface=$LANIF]] = 0) do={
    /interface bridge port add bridge=$LANBR interface=$LANIF
}

:delay 2

# ---- Remove managed IPs safely ----
:foreach id in=[/ip address find comment="NCAE-WAN"] do={
    /ip address remove $id
}
:foreach id in=[/ip address find comment="NCAE-LAN"] do={
    /ip address remove $id
}

# ---- Assign addresses to bridges ----
/ip address add address=$WANIP interface=$WANBR comment="NCAE-WAN"
/ip address add address=$LANIP interface=$LANBR comment="NCAE-LAN"

# ---- Default route ----
:foreach id in=[/ip route find comment="NCAE-Default"] do={
    /ip route remove $id
}
/ip route add dst-address=0.0.0.0/0 gateway=$compGw comment="NCAE-Default"

# ---- DNS ----
/ip dns set servers=$compDns allow-remote-requests=no

# ---- Clean managed NAT rules ----
:foreach id in=[/ip firewall nat find comment~"^NCAE-"] do={
    /ip firewall nat remove $id
}

# Outbound NAT for internal clients
/ip firewall nat add chain=srcnat src-address=$LANNET out-interface=$WANBR action=masquerade comment="NCAE-MASQ"

# Port forwards (source IP unknown, allow from anywhere on WAN)
/ip firewall nat add chain=dstnat in-interface=$WANBR protocol=tcp dst-port=80 action=dst-nat to-addresses=$WEBIP to-ports=80 comment="NCAE-DST-HTTP"
/ip firewall nat add chain=dstnat in-interface=$WANBR protocol=tcp dst-port=443 action=dst-nat to-addresses=$WEBIP to-ports=443 comment="NCAE-DST-HTTPS"
/ip firewall nat add chain=dstnat in-interface=$WANBR protocol=tcp dst-port=53 action=dst-nat to-addresses=$DNSIP to-ports=53 comment="NCAE-DST-DNS-TCP"
/ip firewall nat add chain=dstnat in-interface=$WANBR protocol=udp dst-port=53 action=dst-nat to-addresses=$DNSIP to-ports=53 comment="NCAE-DST-DNS-UDP"
/ip firewall nat add chain=dstnat in-interface=$WANBR protocol=tcp dst-port=5432 action=dst-nat to-addresses=$DBIP to-ports=5432 comment="NCAE-DST-POSTGRES"

# ---- Clean managed filter rules ----
:foreach id in=[/ip firewall filter find comment~"^NCAE-"] do={
    /ip firewall filter remove $id
}

# INPUT chain
/ip firewall filter add chain=input connection-state=established,related action=accept comment="NCAE-IN-EST"
/ip firewall filter add chain=input connection-state=invalid action=drop comment="NCAE-IN-DROP-INVALID"
/ip firewall filter add chain=input in-interface=$WANBR protocol=icmp action=accept comment="NCAE-IN-ICMP-WAN"
/ip firewall filter add chain=input in-interface=$WANBR protocol=tcp dst-port=22 src-address=$compJumphost action=accept comment="NCAE-IN-SSH-COMP-JUMPHOST"
/ip firewall filter add chain=input in-interface=$WANBR protocol=tcp dst-port=22 src-address=$teamJumphost action=accept comment="NCAE-IN-SSH-TEAM-JUMPHOST"
/ip firewall filter add chain=input in-interface=$LANBR protocol=tcp dst-port=22 action=accept comment="NCAE-IN-SSH-LAN"
/ip firewall filter add chain=input in-interface=$WANBR action=drop comment="NCAE-IN-DROP-WAN"

# FORWARD chain
/ip firewall filter add chain=forward connection-state=established,related action=accept comment="NCAE-FWD-EST"
/ip firewall filter add chain=forward connection-state=invalid action=drop comment="NCAE-FWD-DROP-INVALID"

# Allow any inbound WAN traffic that matched a dstnat rule
/ip firewall filter add chain=forward in-interface=$WANBR connection-state=new connection-nat-state=dstnat action=accept comment="NCAE-FWD-ALLOW-PORTFORWARDS"

# Drop anything from WAN that was not port-forwarded
/ip firewall filter add chain=forward in-interface=$WANBR connection-state=new connection-nat-state=!dstnat action=drop comment="NCAE-FWD-DROP-UNFWD-WAN"

# Allow LAN clients to reach required competition infra
/ip firewall filter add chain=forward in-interface=$LANBR dst-address=$compDns protocol=udp dst-port=53 action=accept comment="NCAE-FWD-COMP-DNS-UDP"
/ip firewall filter add chain=forward in-interface=$LANBR dst-address=$compDns protocol=tcp dst-port=53 action=accept comment="NCAE-FWD-COMP-DNS-TCP"
/ip firewall filter add chain=forward in-interface=$LANBR dst-address=$compCdn action=accept comment="NCAE-FWD-CDN"
/ip firewall filter add chain=forward in-interface=$LANBR dst-address=$compCa action=accept comment="NCAE-FWD-CA"

# Backup server to FTP host
/ip firewall filter add chain=forward in-interface=$LANBR src-address=$BACKUPIP dst-address=$FTPIP protocol=tcp dst-port=22 action=accept comment="NCAE-FWD-BACKUP-FTP-SSH"

# Allow LAN clients internet access
/ip firewall filter add chain=forward in-interface=$LANBR out-interface=$WANBR src-address=$LANNET action=accept comment="NCAE-FWD-LAN-INTERNET"

# Reject other new attempts into competition ranges that are not explicitly allowed above
/ip firewall filter add chain=forward in-interface=$LANBR connection-state=new dst-address=$compNet action=reject reject-with=icmp-admin-prohibited comment="NCAE-FWD-REJECT-COMPNET"

# ---- SSH hardening ----
/ip ssh set forwarding-enabled=local strong-crypto=yes

# ---- Minimal service hardening ----
/ip service set telnet disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set ftp disabled=yes

# Leave www/www-ssl/winbox alone for now to avoid breaking access while debugging

# ---- Optional extra hardening that should not break routing ----
/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=none
/tool bandwidth-server set enabled=no
/ip neighbor discovery-settings set discover-interface-list=none
/ip proxy set enabled=no
/ip socks set enabled=no
/ip upnp set enabled=no
/ip cloud set update-time=no

# ---- Set identity ----
/system identity set name=("NCAE-Router-Team" . $TEAM)

:log info ("NCAE router base applied — TEAM=" . $TEAM)

# ===============================
# NCAE Router Config (Idempotent)
# Requires:
#   :global teamNum <n>
#   team_users.txt in Files
# ===============================

:delay 3

# ---- Require explicit team number ----
:global teamNum
:if ([:typeof $teamNum] = "nothing") do={
    :error "Set :global teamNum <n> before running"
}

# ---- Base variables ----
:local wanIfOrig "ether1"
:local lanIfOrig "ether2"
:local wanName "wan"
:local lanName "lan"
:local adminGroup "NICC"
:local rosterFile "team_users.txt"

:local compGw "172.18.0.1"
:local compDns "172.18.0.12"
:local compJumphost "172.18.12.15"
:local compCdn "172.18.13.25"
:local compCa "172.18.0.38"
:local compNet "172.18.0.0/16"

:local wanAddr ("172.18.13." . $teamNum . "/16")
:local wanIpOnly ("172.18.13." . $teamNum)

:local lanAddr ("192.168." . $teamNum . ".1/24")
:local lanIpOnly ("192.168." . $teamNum . ".1")
:local lanNet ("192.168." . $teamNum . ".0/24")

:local teamWeb ("192.168." . $teamNum . ".5")
:local teamDns ("192.168." . $teamNum . ".12")
:local teamDb  ("192.168." . $teamNum . ".7")
:local teamFtp ("172.18.14." . $teamNum)
:local teamBackup ("192.168." . $teamNum . ".15")

:local teamJumphost "172.18.15.1"

:local webfigAllowed ("192.168." . $teamNum . ".101/32,192.168." . $teamNum . ".102/32,192.168." . $teamNum . ".103/32,192.168." . $teamNum . ".104/32,192.168." . $teamNum . ".105/32,192.168." . $teamNum . ".106/32")

# ---- Wait for physical interfaces ----
:local tries 0
:while (([:len [/interface ethernet find where name=$wanIfOrig]] = 0 && [:len [/interface ethernet find where name=$wanName]] = 0) || ([:len [/interface ethernet find where name=$lanIfOrig]] = 0 && [:len [/interface ethernet find where name=$lanName]] = 0)) do={
    :delay 1
    :set tries ($tries + 1)
    :if ($tries > 20) do={
        :error "Timed out waiting for router interfaces"
    }
}

# ---- Rename interfaces once ----
:if (([:len [/interface ethernet find where name=$wanName]] = 0) && ([:len [/interface ethernet find where name=$wanIfOrig]] > 0)) do={
    /interface ethernet set [find where name=$wanIfOrig] name=$wanName
}

:if (([:len [/interface ethernet find where name=$lanName]] = 0) && ([:len [/interface ethernet find where name=$lanIfOrig]] > 0)) do={
    /interface ethernet set [find where name=$lanIfOrig] name=$lanName
}

:delay 2

# ---- IP addresses ----
:foreach id in=[/ip address find where comment="NCAE-WAN"] do={ /ip address remove $id }
:foreach id in=[/ip address find where comment="NCAE-LAN"] do={ /ip address remove $id }

/ip address add address=$wanAddr interface=$wanName comment="NCAE-WAN"
/ip address add address=$lanAddr interface=$lanName comment="NCAE-LAN"

# ---- Default route ----
:foreach id in=[/ip route find where comment="NCAE-Default"] do={ /ip route remove $id }

/ip route add dst-address=0.0.0.0/0 gateway=$compGw comment="NCAE-Default"

# ---- DNS ----
/ip dns set servers=$compDns allow-remote-requests=no

# ---- NAT rules ----
:foreach id in=[/ip firewall nat find where comment~"^NCAE-"] do={ /ip firewall nat remove $id }

/ip firewall nat add chain=srcnat action=masquerade src-address=$lanNet out-interface=$wanName comment="NCAE-MASQ"

/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamWeb in-interface=$wanName protocol=tcp dst-port=80 comment="NCAE-Web-HTTP"
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamWeb in-interface=$wanName protocol=tcp dst-port=443 comment="NCAE-Web-HTTPS"

/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamDns in-interface=$wanName protocol=tcp dst-port=53 comment="NCAE-DNS-TCP"
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamDns in-interface=$wanName protocol=udp dst-port=53 comment="NCAE-DNS-UDP"

/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamDb in-interface=$wanName protocol=tcp dst-port=5432 comment="NCAE-Postgres"

# ---- Firewall filter rules ----
:foreach id in=[/ip firewall filter find where comment~"^NCAE-"] do={ /ip firewall filter remove $id }

# Input chain
/ip firewall filter add chain=input action=accept connection-state=established,related,untracked comment="NCAE-Input-Established"
/ip firewall filter add chain=input action=drop connection-state=invalid comment="NCAE-Input-DropInvalid"

/ip firewall filter add chain=input action=accept in-interface=$wanName protocol=icmp comment="NCAE-Input-AllowICMP-WAN"

/ip firewall filter add chain=input action=accept in-interface=$wanName protocol=tcp dst-port=22 src-address=$compJumphost comment="NCAE-Input-AllowSSH-CompJumphost"
/ip firewall filter add chain=input action=accept in-interface=$wanName protocol=tcp dst-port=22 src-address=$teamJumphost comment="NCAE-Input-AllowSSH-TeamJumphost"

/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=22 comment="NCAE-Input-AllowSSH-LAN"

# WebFig restrictions
/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".101") comment="NCAE-WebFig-Allow-101"
/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".102") comment="NCAE-WebFig-Allow-102"
/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".103") comment="NCAE-WebFig-Allow-103"
/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".104") comment="NCAE-WebFig-Allow-104"
/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".105") comment="NCAE-WebFig-Allow-105"
/ip firewall filter add chain=input action=accept in-interface=$lanName protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".106") comment="NCAE-WebFig-Allow-106"
/ip firewall filter add chain=input action=drop in-interface=$lanName protocol=tcp dst-port=443 comment="NCAE-WebFig-Drop-Other-LAN"

/ip firewall filter add chain=input action=drop in-interface=$wanName comment="NCAE-Input-DropWAN"

# Forward chain
/ip firewall filter add chain=forward action=fasttrack-connection connection-state=established,related comment="NCAE-FWD-FastTrack"
/ip firewall filter add chain=forward action=accept connection-state=established,related comment="NCAE-FWD-Established"
/ip firewall filter add chain=forward action=drop connection-state=invalid comment="NCAE-FWD-DropInvalid"

/ip firewall filter add chain=forward action=drop connection-state=new connection-nat-state=!dstnat in-interface=$wanName comment="NCAE-FWD-DropUnforwardedWAN"

/ip firewall filter add chain=forward action=accept in-interface=$lanName dst-address=$compDns protocol=udp dst-port=53 comment="NCAE-FWD-AllowCompDNS-UDP"
/ip firewall filter add chain=forward action=accept in-interface=$lanName dst-address=$compDns protocol=tcp dst-port=53 comment="NCAE-FWD-AllowCompDNS-TCP"

/ip firewall filter add chain=forward action=accept in-interface=$lanName dst-address=$compCdn comment="NCAE-FWD-AllowCDN"
/ip firewall filter add chain=forward action=accept in-interface=$lanName dst-address=$compCa comment="NCAE-FWD-AllowCA"

/ip firewall filter add chain=forward action=accept in-interface=$lanName src-address=$teamBackup dst-address=$teamFtp protocol=tcp dst-port=22 comment="NCAE-FWD-BackupToFTP-SSH"

# *** FIX: Allow LAN clients internet access ***
/ip firewall filter add chain=forward action=accept in-interface=$lanName out-interface=$wanName src-address=$lanNet comment="NCAE-FWD-AllowLANInternet"

/ip firewall filter add chain=forward action=reject reject-with=icmp-admin-prohibited connection-state=new in-interface=$lanName dst-address=$compNet comment="NCAE-FWD-RejectUnknownCompWAN"

# ---- SSH hardening ----
/ip ssh set forwarding-enabled=local strong-crypto=yes

# ---- Services ----
/ip service set www-ssl certificate=webfig address=$webfigAllowed disabled=no
/ip service set www disabled=yes
/ip service set telnet disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox disabled=yes
/ip service set ftp disabled=yes

# ---- Identity ----
/system identity set name=("NCAE-Router-Team" . $teamNum)

:log info ("NCAE router config applied successfully for team " . $teamNum)

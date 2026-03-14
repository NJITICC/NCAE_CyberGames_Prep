# ===============================
# NCAE Router Config (Idempotent)
# Bridge-safe WAN/LAN handling
#
# Requires:
#   :global teamNum <n>
#   team_users.txt in Files
#
# team_users.txt format:
#   name | password | ssh-ed25519 AAAA... comment
#   # comments allowed
#   use "-" as password to preserve existing password
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

# Only these internal blue team VMs can reach WebFig
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

# ---- Detect real L3/filtering interfaces ----
# If WAN/LAN bridge objects exist, use them instead of slave ports.
:local wanPathIf $wanName
:if ([:len [/interface find where name="WAN"]] > 0) do={
    :set wanPathIf "WAN"
}

:local lanPathIf $lanName
:if ([:len [/interface find where name="LAN"]] > 0) do={
    :set lanPathIf "LAN"
}

:log info ("Using WAN path interface: " . $wanPathIf)
:log info ("Using LAN path interface: " . $lanPathIf)

# ---- IP addresses ----
:foreach id in=[/ip address find where comment="NCAE-WAN"] do={ /ip address remove $id }
:foreach id in=[/ip address find where comment="NCAE-LAN"] do={ /ip address remove $id }

/ip address add address=$wanAddr interface=$wanPathIf comment="NCAE-WAN"
/ip address add address=$lanAddr interface=$lanPathIf comment="NCAE-LAN"

# ---- Default route ----
:foreach id in=[/ip route find where comment="NCAE-Default"] do={ /ip route remove $id }
/ip route add dst-address=0.0.0.0/0 gateway=$compGw comment="NCAE-Default"

# ---- DNS ----
/ip dns set servers=$compDns allow-remote-requests=no

# ---- NAT rules ----
:foreach id in=[/ip firewall nat find where comment~"^NCAE-"] do={ /ip firewall nat remove $id }

/ip firewall nat add chain=srcnat action=masquerade src-address=$lanNet out-interface=$wanPathIf comment="NCAE-MASQ"

/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamWeb in-interface=$wanPathIf protocol=tcp dst-port=80 comment="NCAE-Web-HTTP"
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamWeb in-interface=$wanPathIf protocol=tcp dst-port=443 comment="NCAE-Web-HTTPS"
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamDns in-interface=$wanPathIf protocol=tcp dst-port=53 comment="NCAE-DNS-TCP"
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamDns in-interface=$wanPathIf protocol=udp dst-port=53 comment="NCAE-DNS-UDP"
/ip firewall nat add chain=dstnat action=dst-nat to-addresses=$teamDb in-interface=$wanPathIf protocol=tcp dst-port=5432 comment="NCAE-Postgres"

# ---- Firewall filter rules ----
:foreach id in=[/ip firewall filter find where comment~"^NCAE-"] do={ /ip firewall filter remove $id }

# Input chain
/ip firewall filter add chain=input action=accept connection-state=established,related,untracked comment="NCAE-Input-Established"
/ip firewall filter add chain=input action=drop connection-state=invalid comment="NCAE-Input-DropInvalid"

/ip firewall filter add chain=input action=accept in-interface=$wanPathIf protocol=icmp comment="NCAE-Input-AllowICMP-WAN"
/ip firewall filter add chain=input action=accept in-interface=$wanPathIf protocol=tcp dst-port=22 src-address=$compJumphost comment="NCAE-Input-AllowSSH-CompJumphost"
/ip firewall filter add chain=input action=accept in-interface=$wanPathIf protocol=tcp dst-port=22 src-address=$teamJumphost comment="NCAE-Input-AllowSSH-TeamJumphost"

# LAN SSH — allow internal machines to SSH to router
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=22 comment="NCAE-Input-AllowSSH-LAN"

# WebFig only from internal blue team VMs
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".101") comment="NCAE-WebFig-Allow-101"
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".102") comment="NCAE-WebFig-Allow-102"
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".103") comment="NCAE-WebFig-Allow-103"
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".104") comment="NCAE-WebFig-Allow-104"
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".105") comment="NCAE-WebFig-Allow-105"
/ip firewall filter add chain=input action=accept in-interface=$lanPathIf protocol=tcp dst-port=443 src-address=("192.168." . $teamNum . ".106") comment="NCAE-WebFig-Allow-106"
/ip firewall filter add chain=input action=drop in-interface=$lanPathIf protocol=tcp dst-port=443 comment="NCAE-WebFig-Drop-Other-LAN"

# Drop everything else to router from WAN
/ip firewall filter add chain=input action=drop in-interface=$wanPathIf comment="NCAE-Input-DropWAN"

# Forward chain
/ip firewall filter add chain=forward action=fasttrack-connection connection-state=established,related comment="NCAE-FWD-FastTrack"
/ip firewall filter add chain=forward action=accept connection-state=established,related comment="NCAE-FWD-Established"
/ip firewall filter add chain=forward action=drop connection-state=invalid comment="NCAE-FWD-DropInvalid"

# Explicitly allow any inbound WAN traffic that matched a dstnat rule
# This keeps scoring working even if the scoring server source IP is unknown.
/ip firewall filter add chain=forward action=accept in-interface=$wanPathIf connection-state=new connection-nat-state=dstnat comment="NCAE-FWD-AllowPortForwards"

# Drop new WAN traffic that is not part of a port forward
/ip firewall filter add chain=forward action=drop connection-state=new connection-nat-state=!dstnat in-interface=$wanPathIf comment="NCAE-FWD-DropUnforwardedWAN"

# Explicitly allowed LAN -> competition services
/ip firewall filter add chain=forward action=accept in-interface=$lanPathIf dst-address=$compDns protocol=udp dst-port=53 comment="NCAE-FWD-AllowCompDNS-UDP"
/ip firewall filter add chain=forward action=accept in-interface=$lanPathIf dst-address=$compDns protocol=tcp dst-port=53 comment="NCAE-FWD-AllowCompDNS-TCP"
/ip firewall filter add chain=forward action=accept in-interface=$lanPathIf dst-address=$compCdn comment="NCAE-FWD-AllowCDN"
/ip firewall filter add chain=forward action=accept in-interface=$lanPathIf dst-address=$compCa comment="NCAE-FWD-AllowCA"
/ip firewall filter add chain=forward action=accept in-interface=$lanPathIf src-address=$teamBackup dst-address=$teamFtp protocol=tcp dst-port=22 comment="NCAE-FWD-BackupToFTP-SSH"

# Allow internal clients internet access
/ip firewall filter add chain=forward action=accept in-interface=$lanPathIf out-interface=$wanPathIf src-address=$lanNet comment="NCAE-FWD-AllowLANInternet"

# Reject new LAN traffic aimed at competition ranges that is not specifically allowed above
/ip firewall filter add chain=forward action=reject reject-with=icmp-admin-prohibited connection-state=new in-interface=$lanPathIf dst-address=$compNet comment="NCAE-FWD-RejectUnknownCompWAN"

# ---- SSH hardening ----
/ip ssh set forwarding-enabled=local strong-crypto=yes

# ---- NICC group ----
:if ([:len [/user group find where name=$adminGroup]] = 0) do={
    /user group add name=$adminGroup policy="local,ssh,web,reboot,read,write,policy,test,sensitive,sniff" comment="NCAE-Managed"
} else={
    /user group set [find where name=$adminGroup] policy="local,ssh,web,reboot,read,write,policy,test,sensitive,sniff" comment="NCAE-Managed"
}

# ---- team_users.txt sync ----
:if ([:len [/file find where name=$rosterFile]] = 0) do={
    :error ("Missing roster file: " . $rosterFile)
}

:local roster [/file get $rosterFile contents]
:local data ($roster . "\n")
:local pos 0

:while ($pos < [:len $data]) do={

    :local nl [:find $data "\n" $pos]
    :if ($nl = nil) do={ :set nl [:len $data] }

    :local line [:pick $data $pos $nl]
    :set pos ($nl + 1)

    # Strip CR if file came from Windows
    :if (([:len $line] > 0) && ([:pick $line ([:len $line] - 1) [:len $line]] = "\r")) do={
        :set line [:pick $line 0 ([:len $line] - 1)]
    }

    # Trim line
    :while (([:len $line] > 0) && ([:pick $line 0 1] = " ")) do={
        :set line [:pick $line 1 [:len $line]]
    }
    :while (([:len $line] > 0) && ([:pick $line ([:len $line] - 1) [:len $line]] = " ")) do={
        :set line [:pick $line 0 ([:len $line] - 1)]
    }

    # Skip blanks/comments
    :if ([:len $line] = 0) do={ :continue }
    :if ([:pick $line 0 1] = "#") do={ :continue }

    # Parse name | password | pubkey
    :local p1 [:find $line "|"]
    :local p2 [:find $line "|" ($p1 + 1)]

    :if (($p1 = nil) || ($p2 = nil)) do={
        :log warning ("Skipping malformed roster line: " . $line)
        :continue
    }

    :local username [:pick $line 0 $p1]
    :local password [:pick $line ($p1 + 1) $p2]
    :local pubKey   [:pick $line ($p2 + 1) [:len $line]]

    # Trim username
    :while (([:len $username] > 0) && ([:pick $username 0 1] = " ")) do={
        :set username [:pick $username 1 [:len $username]]
    }
    :while (([:len $username] > 0) && ([:pick $username ([:len $username] - 1) [:len $username]] = " ")) do={
        :set username [:pick $username 0 ([:len $username] - 1)]
    }

    # Trim password
    :while (([:len $password] > 0) && ([:pick $password 0 1] = " ")) do={
        :set password [:pick $password 1 [:len $password]]
    }
    :while (([:len $password] > 0) && ([:pick $password ([:len $password] - 1) [:len $password]] = " ")) do={
        :set password [:pick $password 0 ([:len $password] - 1)]
    }

    # Trim pubKey
    :while (([:len $pubKey] > 0) && ([:pick $pubKey 0 1] = " ")) do={
        :set pubKey [:pick $pubKey 1 [:len $pubKey]]
    }
    :while (([:len $pubKey] > 0) && ([:pick $pubKey ([:len $pubKey] - 1) [:len $pubKey]] = " ")) do={
        :set pubKey [:pick $pubKey 0 ([:len $pubKey] - 1)]
    }

    :if (([:len $username] = 0) || ([:len $pubKey] = 0)) do={
        :log warning ("Skipping incomplete roster line: " . $line)
        :continue
    }

    # Create or update user
    :if ([:len [/user find where name=$username]] = 0) do={
        :if ($password = "-") do={
            /user add name=$username group=$adminGroup comment=("NCAE-Managed-Team" . $teamNum)
        } else={
            /user add name=$username group=$adminGroup password=$password comment=("NCAE-Managed-Team" . $teamNum)
        }
        :log info ("Created user " . $username)
    } else={
        /user set [find where name=$username] group=$adminGroup comment=("NCAE-Managed-Team" . $teamNum)
        :if ($password != "-") do={
            /user set [find where name=$username] password=$password
        }
        :log info ("Updated user " . $username)
    }

    # Replace user's SSH keys so reruns stay clean
    :foreach kid in=[/user ssh-keys find where user=$username] do={
        /user ssh-keys remove $kid
    }

    :do {
        /user ssh-keys add user=$username key=$pubKey
        :log info ("Installed SSH key for " . $username)
    } on-error={
        :log error ("Failed to add SSH key for " . $username . " — check roster key format")
    }
}

# ---- Certificate for WebFig ----
:if ([:len [/certificate find where name="webfig"]] = 0) do={
    /certificate add name=webfig common-name=$lanIpOnly
    /certificate sign webfig
    :delay 2
}

# ---- Services ----
/ip service set www-ssl certificate=webfig address=$webfigAllowed disabled=no
/ip service set www disabled=yes
/ip service set telnet disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox disabled=yes
/ip service set ftp disabled=yes

# ---- Extra hardening ----
/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=none
/tool bandwidth-server set enabled=no
/ip neighbor discovery-settings set discover-interface-list=none
/ip proxy set enabled=no
/ip socks set enabled=no
/ip upnp set enabled=no
/ip cloud set update-time=no

# ---- Identity ----
/system identity set name=("NCAE-Router-Team" . $teamNum)

:log info ("NCAE router config applied successfully for team " . $teamNum)

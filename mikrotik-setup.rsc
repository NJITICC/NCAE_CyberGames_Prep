{
:local wanInterface ether1
:local lanInterface ether2
:local teamNum 9
:local wanAddr "172.18.13.$teamNum/16"
:local lanAddr "192.168.$teamNum.1/24"
:local compGw 172.18.0.1
:local compDns 172.18.0.12
:local teamWeb "192.168.$teamNum.5"
:local teamDns "192.168.$teamNum.12"
:local teamDb  "192.168.$teamNum.7"
:local compJumphost 172.18.12.15
:local compCdn 172.18.13.25
:local compCa 172.18.0.38
:local teamFtp "172.18.14.$teamNum"
:local teamBackup "192.168.$teamNum.15"

# IP Calculations from https://forum.mikrotik.com/viewtopic.php?t=194019#p987206
# WAN IP Calculations
:local wanIp [:toip [:pick $wanAddr 0 [:find $wanAddr "/"]]]
:local wanCidr [:tonum [:pick $wanAddr ([:find $wanAddr "/"] + 1) [:len $wanAddr]]]
:local wanSubmask (255.255.255.255<<(32 - $wanCidr))
:local wanNetwork ($wanIp & $wanSubmask)

# LAN IP Calculations
:local lanIp [:toip [:pick $lanAddr 0 [:find $lanAddr "/"]]]
:local lanCidr [:tonum [:pick $lanAddr ([:find $lanAddr "/"] + 1) [:len $lanAddr]]]
:local lanSubmask (255.255.255.255<<(32 - $lanCidr))
:local lanNetwork ($lanIp & $lanSubmask)

# Interface Assignments
/interface ethernet
  set $wanInterface name=wan
  set $lanInterface name=lan

# IP Address Assignments
/ip address
  add address=$wanAddr interface=wan
  add address=$lanAddr interface=lan

# Default Gateway
/ip route add gateway=$compGw

# DNS
/ip dns set servers=$compDns

# NAT
/ip firewall nat
  add chain=srcnat action=masquerade src-address="$lanNetwork/$lanCidr" out-interface=wan

# Port Forwards
  add chain=dstnat action=dst-nat to-address=$teamWeb in-interface=wan dst-port=80 protocol=tcp comment="Web HTTP"
  add chain=dstnat action=dst-nat to-address=$teamWeb in-interface=wan dst-port=443 protocol=tcp comment="Web HTTPS"
  add chain=dstnat action=dst-nat to-address=$teamDns in-interface=wan dst-port=53 protocol=tcp comment="DNS TCP"
  add chain=dstnat action=dst-nat to-address=$teamDns in-interface=wan dst-port=53 protocol=udp comment="DNS UDP"
  add chain=dstnat action=dst-nat to-address=$teamDb in-interface=wan dst-port=5432 protocol=tcp comment="Postgres TCP"

# Firewall
/ip firewall filter
  add chain=input action=accept connection-state=established,related,untracked comment="Accept established,related,untracked"
  add chain=input action=drop connection-state=invalid comment="Drop Invalid"
  add chain=input in-interface=wan action=accept protocol=icmp comment="Accept ICMP from WAN"
  add chain=input in-interface=wan action=accept protocol=tcp port=22 src-address=$compJumphost comment="Allow SSH from Jumphost"
  add chain=input in-interface=wan action=drop comment="Block Everything Else"
  add chain=forward action=fasttrack-connection connection-state=established,related \
    comment="fast-track for established,related";
  add chain=forward action=accept connection-state=established,related \
    comment="accept established,related";
  add chain=forward action=drop connection-state=invalid
  add chain=forward action=drop connection-state=new connection-nat-state=!dstnat \
    in-interface=wan comment="Drop anything from WAN not port forwarded"
  add chain=forward action=accept in-interface=lan dst-address=$compDns protocol=udp port=53 comment="Allow Access to DNS"
  add chain=forward action=accept in-interface=lan dst-address=$compCdn comment="Allow Access to CDN"
  add chain=forward action=accept in-interface=lan dst-address=$compCa comment="Allow Access to CA"
  add chain=forward action=accept in-interface=lan src-address=$teamBackup port=22 protocol=tcp dst-address=$teamFtp \
    comment="Allow SSH Access to FTP from Backup"
  add chain=forward action=reject connection-state=new in-interface=lan dst-address="$wanNetwork/$wanCidr" \
    comment="Reject anything from LAN to unknown WAN (except public Internet)"

# SSH
/ip ssh
  set forwarding-enabled=local
  set strong-crypto=yes

# Users
/user
  group add name="highlanders" policy="local,ssh,web,reboot,read,write,policy,test,sensitive,sniff" comment="Highlanders"
# REPEAT FOR ALL USERS
  add name="USERNAME" group="highlanders" password="RANDOM"

# SSH Keys
/user ssh-keys
  # REPEAT FOR ALL USERS
  add user="USERNAME" key="SSH KEY"

# Services
/certificate
  add name=webfig common-name=$lanIp
  sign webfig
/ip service
  set www-ssl certificate=webfig disabled=no
  set www disabled=yes
  set telnet disabled=yes
  set api disabled=yes
  set winbox disabled=yes
  set api-ssl disabled=yes
  set ftp disabled=yes
/tool mac-server
  set allowed-interface-list=none
  mac-winbox set allowed-interface-list=none
  ping set enabled=no
/tool bandwidth-server set enabled=no 
/ip
  neighbor discovery-settings set discover-interface-list=none 
  dns set allow-remote-requests=no
  proxy set enabled=no
  socks set enabled=no
  upnp set enabled=no
  cloud set update-time=no
}
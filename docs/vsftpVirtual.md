# VSFTP Set Up - Virtual users in VsFtpd

By: Judrianne "Jude" Mahigne

System: Rocky Linux 8.10 (Green Obsidian)

>man page: https://linux.die.net/man/5/vsftpd.conf

## Install vsftpd
`sudo dnf install -y vsftpd`
## Enable and Start Service
```bash
sudo systemctl enable --now vsftpd
```
## Create mapped FTP user
Ensure the directory is owned by ftpuser and is writable. This user will be used for all virtual FTP sessions.
```bash
sudo useradd -d /mnt/ftp -s /sbin/nologin ftpuser
sudo mkdir -p /mnt/ftp
sudo chown ftpuser:ftpuser /mnt/ftp
sudo chmod 755 /mnt/ftp
```
## Open FTP in firewall
### If using firewall-cmd
```bash
sudo firewall-cmd --permanent --add-service=ftp
sudo firewall-cmd --permanent --add-port=40000-50000/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```
### If using nftables
> NOTE: If using nftables exclusively (meaning no firewall-cmd), then firewall-cmd must be disabled to work.

Create the config file. I named mine `nft.conf`
```bash
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    # Allow loopback
    iifname lo accept
    # Accept only from one ip or a subnet and set one or more ports to accept
    ip saddr 172.18.14.0/24 tcp dport {21,22,40000-50000} ct state new accept
    # Accept established and related connections
    ip saddr 172.18.14.0/24 ct state established,related accept
    # Log and drop the rest
    log prefix "nftables-drop: " flags all counter drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
```

## Check if SELinux is Enforcing
### If SELinux is not Enforcing skip this part
How to check if SELinux is enforcing
```bash
getenforce
```
Enable full access for ftpd
```bash
sudo setsebool -P ftpd_full_access=1
sudo setsebool -P ftpd_use_passive_mode=1
```
Set context for directory using semanage
```bash
sudo semanage fcontext -a -t public_content_rw_t "/mnt/ftp(/.*)?"
sudo restorecon -Rv /mnt/ftp
```
## Create or assign shared FTP directory
>For the regional competition, the scoring users directory was `/mnt/files`

Set root permissions for parent directory
```bash 
sudo chown root:root /mnt
sudo chmod 755 /mnt
```
Set uploadable (read/write) directory
```bash
sudo chown ftpuser:ftpuser /mnt/ftp
sudo chmod 775 /mnt/ftp
```

## Configure vsftpd.conf

`/etc/vsftpd/vsftpd.conf`
```bash
# I think this keeps the hacktivist group Anonymous away
anonymous_enable=NO
# Uncomment this to allow local users to log in.
local_enable=YES
# Uncomment this to enable any form of FTP write command.
write_enable=YES
# Write even to jailed chroot
allow_writeable_chroot=YES
# Default umask for local users is 077. You may wish to change this to 022,
local_umask=022
# Logging
userlist_log=YES
xferlog_enable=YES
log_ftp_protocol=YES
syslog_enable=YES
# Make sure PORT transfer connections originate from port 20 (ftp-data).
connect_from_port_20=YES
# Chroot. This is based on the previous competition.
local_root=/mnt/ftp
chroot_local_user=YES
# Virtual users
guest_enable=YES
guest_username=ftpuser
virtual_use_local_privs=YES
# When "listen" directive is enabled, vsftpd runs in standalone mode and
# listens on IPv4 sockets. This directive cannot be used in conjunction
# with the listen_ipv6 directive. 
# FIREWALL MUST BE PROPERLY CONFIGURED FIRST!!!!
listen=YES
listen_ipv6=NO
# If you want vsftpd to run on the environment where the reverse lookup for some 
# hostname is available and the name server doesn't respond for a while, you should 
# set this to NO to avoid a performance issue. 
reverse_lookup_enable=NO
# PAM
pam_service_name=vsftpd
# Make sure to create the user list to allow users
userlist_enable=YES
userlist_file=/etc/vsftpd/vsftpd.userlist
userlist_deny=NO
# Passive mode
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
# All user and group information in directory listings will be displayed as "ftp".
hide_ids=YES
```
## Configure User Access List
To allow only specific system users to log in via FTP, add them to:
```bash
sudo nano /etc/vsftpd/vsftpd.userlist
```
Example from previous competition
```bash
camille_jenatzy
gaston_chasseloup
leon_serpollet
william_vanderbilt
henri_fournier
maurice_augieres
arthur_duray
henry_ford
louis_rigolly
```
## LOCK IT DOWN
```bash
sudo chattr +i /etc/vsftpd/vsftpd.conf
sudo chattr +i /etc/vsftpd/vsftpd.userlist
sudo chattr +i /etc/pam.d/vsftpd
```
>Use `sudo chattr -i <filename>` in order to modify them afterwards

## Restart and hope for the best...
`sudo systemctl restart vsftpd`

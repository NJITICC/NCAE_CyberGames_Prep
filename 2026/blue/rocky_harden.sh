#!/usr/bin/env bash
set -euo pipefail

# NCAE Rocky Linux 9 Hardening Script
# CIS Level 1-inspired, role-aware, competition-safe baseline
# Intended roles: dns, smb
#
# Notes:
# - Does NOT remove persistence. Use blue_recover separately.
# - Avoids disruptive/manual CIS items that are risky in competition.
# - Keeps required role services open.
# - AIDE is timeout-protected so it cannot hang the whole script.

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Select Rocky role:"
  echo "1) dns"
  echo "2) smb"
  read -r -p "Enter choice: " choice
  case "$choice" in
    1) ROLE="dns" ;;
    2) ROLE="smb" ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
fi

case "$ROLE" in
  dns|smb) ;;
  *) echo "Role must be dns or smb"; exit 1 ;;
esac

echo "[*] Role: $ROLE"

echo "[*] Updating packages"
dnf -y update

echo "[*] Installing baseline packages"
dnf -y install \
  firewalld \
  nftables \
  audit \
  aide \
  rsyslog \
  sudo \
  chrony \
  libpwquality \
  policycoreutils-python-utils \
  openssh-server

echo "[*] Enabling core services"
systemctl enable --now firewalld
systemctl enable --now auditd || true
systemctl enable --now rsyslog
systemctl enable --now chronyd
systemctl enable --now sshd

echo "[*] Enforcing SELinux"
sed -ri 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config || true
setenforce 1 || true

echo "[*] Disabling uncommon filesystem and network modules"
cat >/etc/modprobe.d/ncae-cis-disable.conf <<'EOF'
install cramfs /bin/false
blacklist cramfs

install freevxfs /bin/false
blacklist freevxfs

install hfs /bin/false
blacklist hfs

install hfsplus /bin/false
blacklist hfsplus

install jffs2 /bin/false
blacklist jffs2

install udf /bin/false
blacklist udf

install usb-storage /bin/false
blacklist usb-storage

install dccp /bin/false
blacklist dccp

install tipc /bin/false
blacklist tipc

install rds /bin/false
blacklist rds

install sctp /bin/false
blacklist sctp
EOF

for mod in cramfs freevxfs hfs hfsplus jffs2 udf usb-storage dccp tipc rds sctp; do
  modprobe -r "$mod" 2>/dev/null || true
  rmmod "$mod" 2>/dev/null || true
done

echo "[*] Applying sysctl protections"
cat >/etc/sysctl.d/99-ncae-cis.conf <<'EOF'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false
fs.protected_fifos = 1
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_symlinks = 1
EOF
sysctl --system

echo "[*] Hardening SSH"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

ensure_sshd() {
  local key="$1"
  local value="$2"
  if grep -qiE "^[#[:space:]]*${key}\b" /etc/ssh/sshd_config; then
    sed -ri "s|^[#[:space:]]*${key}\b.*|${key} ${value}|I" /etc/ssh/sshd_config
  else
    echo "${key} ${value}" >> /etc/ssh/sshd_config
  fi
}

ensure_sshd "PermitRootLogin" "no"
ensure_sshd "PermitEmptyPasswords" "no"
ensure_sshd "MaxAuthTries" "4"
ensure_sshd "ClientAliveInterval" "300"
ensure_sshd "ClientAliveCountMax" "0"
ensure_sshd "LoginGraceTime" "60"
ensure_sshd "X11Forwarding" "no"
ensure_sshd "PermitUserEnvironment" "no"
ensure_sshd "IgnoreRhosts" "yes"
ensure_sshd "HostbasedAuthentication" "no"
ensure_sshd "GSSAPIAuthentication" "no"
ensure_sshd "DisableForwarding" "yes"
ensure_sshd "UsePAM" "yes"
ensure_sshd "Banner" "/etc/issue.net"
ensure_sshd "MaxStartups" "10:30:60"
ensure_sshd "MaxSessions" "10"

chmod 600 /etc/ssh/sshd_config
sshd -t
systemctl restart sshd

echo "[*] Configuring login banner"
cat >/etc/issue.net <<'EOF'
Authorized uses only. All activity may be monitored and reported.
EOF
chmod 644 /etc/issue.net

echo "[*] Hardening sudo"
mkdir -p /etc/sudoers.d
cat >/etc/sudoers.d/99-ncae-hardening <<'EOF'
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
Defaults timestamp_timeout=15
EOF
chmod 440 /etc/sudoers.d/99-ncae-hardening
visudo -cf /etc/sudoers >/dev/null
visudo -cf /etc/sudoers.d/99-ncae-hardening >/dev/null

echo "[*] Configuring pwquality"
mkdir -p /etc/security/pwquality.conf.d
cat >/etc/security/pwquality.conf.d/99-ncae.conf <<'EOF'
minlen = 14
minclass = 4
maxrepeat = 3
maxsequence = 3
dictcheck = 1
enforce_for_root
EOF

echo "[*] Configuring faillock"
authselect current >/dev/null 2>&1 && authselect enable-feature with-faillock || true
cat >/etc/security/faillock.conf <<'EOF'
deny = 5
unlock_time = 900
even_deny_root
root_unlock_time = 900
EOF

echo "[*] Configuring auditd basic settings"
sed -ri 's/^\s*max_log_file\s*=.*/max_log_file = 50/' /etc/audit/auditd.conf || true
sed -ri 's/^\s*max_log_file_action\s*=.*/max_log_file_action = keep_logs/' /etc/audit/auditd.conf || true
sed -ri 's/^\s*space_left_action\s*=.*/space_left_action = email/' /etc/audit/auditd.conf || true
sed -ri 's/^\s*admin_space_left_action\s*=.*/admin_space_left_action = halt/' /etc/audit/auditd.conf || true

cat >/etc/audit/rules.d/99-ncae.rules <<'EOF'
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /var/log/sudo.log -p wa -k actions
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd
-e 2
EOF
augenrules --load || true
systemctl restart auditd || true

echo "[*] Configuring rsyslog/journald"
mkdir -p /var/log/journal
sed -ri 's/^#?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf || echo "Storage=persistent" >> /etc/systemd/journald.conf
sed -ri 's/^#?Compress=.*/Compress=yes/' /etc/systemd/journald.conf || echo "Compress=yes" >> /etc/systemd/journald.conf
systemctl restart systemd-journald
systemctl restart rsyslog

echo "[*] Fixing sensitive file permissions"
chmod 644 /etc/passwd /etc/group
chmod 000 /etc/shadow /etc/gshadow || true
chown root:root /etc/passwd /etc/group
chown root:root /etc/shadow /etc/gshadow || true

echo "[*] Initializing AIDE if needed"
if [[ ! -f /var/lib/aide/aide.db.gz && ! -f /var/lib/aide/aide.db ]]; then
  rm -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db.new.gz
  if timeout 180 aide --init; then
    if [[ -f /var/lib/aide/aide.db.new.gz ]]; then
      mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
      echo "[+] AIDE initialized"
    elif [[ -f /var/lib/aide/aide.db.new ]]; then
      mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
      echo "[+] AIDE initialized"
    else
      echo "[!] AIDE finished but no new database file was found"
    fi
  else
    echo "[!] AIDE init timed out or failed, skipping"
    pkill -x aide 2>/dev/null || true
  fi
fi

echo "[*] Scheduling daily AIDE check"
cat >/etc/cron.daily/aide-check <<'EOF'
#!/usr/bin/env bash
/usr/sbin/aide --check >/var/log/aide-check.log 2>&1
EOF
chmod 700 /etc/cron.daily/aide-check

echo "[*] Applying firewall rules"
firewall-cmd --permanent --set-default-zone=public
firewall-cmd --permanent --remove-service=dhcpv6-client || true
firewall-cmd --permanent --add-service=ssh

if [[ "$ROLE" == "dns" ]]; then
  firewall-cmd --permanent --add-service=dns
  firewall-cmd --permanent --remove-service=samba || true
fi

if [[ "$ROLE" == "smb" ]]; then
  firewall-cmd --permanent --add-service=samba
  firewall-cmd --permanent --remove-service=dns || true
fi

firewall-cmd --reload

echo "[*] Verifying role services stay up"
if [[ "$ROLE" == "dns" ]]; then
  systemctl enable --now named 2>/dev/null || true
fi

if [[ "$ROLE" == "smb" ]]; then
  systemctl enable --now smb 2>/dev/null || systemctl enable --now smb.service 2>/dev/null || true
  systemctl enable --now nmb 2>/dev/null || true
fi

echo
echo "[+] Hardening complete for Rocky role: $ROLE"
echo "[+] Listening ports:"
ss -tulpn
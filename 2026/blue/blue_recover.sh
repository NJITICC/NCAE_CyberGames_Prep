#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# NCAE Blue Recover Script
# Purpose:
#   Competition-safe incident response / persistence cleanup
#
# What it does:
#   - Detects OS
#   - Asks for role
#   - Creates quarantine directory
#   - Reviews and quarantines common persistence
#   - Preserves likely scoring services
#   - Prints findings and verification output
#
# What it does NOT do:
#   - Full CIS hardening
#   - Blindly delete everything
#   - Remove package-installed service units wholesale
#
# Intended workflow:
#   1) sudo ./blue_recover.sh
#   2) sudo ./rocky_harden.sh <role>   OR   sudo ./ubuntu_harden.sh <role>
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

TIMESTAMP="$(date +%F_%H-%M-%S)"
HOST="$(hostname)"
QUAR_DIR="/root/blue_quarantine_${HOST}_${TIMESTAMP}"
LOG_FILE="/root/blue_recover_${HOST}_${TIMESTAMP}.log"

mkdir -p "$QUAR_DIR"
touch "$LOG_FILE"

log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

move_quarantine() {
  local src="$1"
  if [[ -e "$src" || -L "$src" ]]; then
    local dest="$QUAR_DIR$(echo "$src" | sed 's#/#_#g')"
    log "[!] Quarantining: $src -> $dest"
    mv "$src" "$dest" 2>/dev/null || cp -a "$src" "$dest" 2>/dev/null || true
  fi
}

service_exists() {
  systemctl list-unit-files | awk '{print $1}' | grep -qx "$1"
}

is_debian=0
is_redhat=0

if [[ -f /etc/debian_version ]]; then
  is_debian=1
elif [[ -f /etc/redhat-release ]]; then
  is_redhat=1
else
  log "[-] Unsupported OS"
  exit 1
fi

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Select role:"
  echo "1) web"
  echo "2) db"
  echo "3) dns"
  echo "4) smb"
  echo "5) backup"
  read -r -p "Enter choice: " choice
  case "$choice" in
    1) ROLE="web" ;;
    2) ROLE="db" ;;
    3) ROLE="dns" ;;
    4) ROLE="smb" ;;
    5) ROLE="backup" ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
fi

case "$ROLE" in
  web|db|dns|smb|backup) ;;
  *) echo "Role must be web, db, dns, smb, or backup"; exit 1 ;;
esac

log "[*] Host: $HOST"
log "[*] Role: $ROLE"
log "[*] Quarantine dir: $QUAR_DIR"
log "[*] Log file: $LOG_FILE"

# ------------------------------------------------------------
# Role-based service allowlist
# ------------------------------------------------------------
REQ_SERVICES=("ssh" "sshd")
REQ_PORTS=("22")

case "$ROLE" in
  web)
    REQ_SERVICES+=("apache2" "httpd")
    REQ_PORTS+=("80" "443")
    ;;
  db)
    REQ_SERVICES+=("postgresql")
    REQ_PORTS+=("5432")
    ;;
  dns)
    REQ_SERVICES+=("named" "bind9")
    REQ_PORTS+=("53")
    ;;
  smb)
    REQ_SERVICES+=("smb" "smbd" "nmb")
    REQ_PORTS+=("139" "445")
    ;;
  backup)
    # ssh only
    ;;
esac

# ------------------------------------------------------------
# 1. Snapshot useful state
# ------------------------------------------------------------
log "\n===== CURRENT STATE SNAPSHOT ====="
{
  echo "---- date"
  date
  echo "---- hostname"
  hostnamectl 2>/dev/null || hostname
  echo "---- who"
  who || true
  echo "---- last logins"
  last -n 10 || true
  echo "---- listening ports"
  ss -tulpn || true
  echo "---- running services"
  systemctl --type=service --state=running || true
} >>"$LOG_FILE" 2>&1

# ------------------------------------------------------------
# 2. Check local users
# ------------------------------------------------------------
log "\n===== USER REVIEW ====="
mapfile -t interactive_users < <(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1 ":" $6 ":" $7}' /etc/passwd)

for entry in "${interactive_users[@]:-}"; do
  user="${entry%%:*}"
  rest="${entry#*:}"
  home="${rest%%:*}"
  shell="${entry##*:}"

  log "[*] User: $user | Home: $home | Shell: $shell"

  if [[ "$shell" == "/bin/bash" || "$shell" == "/bin/sh" || "$shell" == "/bin/zsh" ]]; then
    :
  else
    log "[?] Non-standard shell for $user: $shell"
  fi
done

log "\n[*] Users with UID 0:"
awk -F: '$3 == 0 {print $1}' /etc/passwd | tee -a "$LOG_FILE"

# ------------------------------------------------------------
# 3. Authorized keys review
# ------------------------------------------------------------
log "\n===== SSH KEY REVIEW ====="
for base in /root /home/*; do
  [[ -d "$base" ]] || continue
  ak="$base/.ssh/authorized_keys"
  if [[ -f "$ak" ]]; then
    log "\n[*] Found authorized_keys: $ak"
    nl -ba "$ak" | tee -a "$LOG_FILE"

    backup="$QUAR_DIR$(echo "$ak" | sed 's#/#_#g').bak"
    cp -a "$ak" "$backup" 2>/dev/null || true

    # Remove empty lines and obvious comments only if present, otherwise preserve file.
    # User can manually compare against known-good later.
    chmod 600 "$ak" 2>/dev/null || true
    chown "$(stat -c '%U:%G' "$(dirname "$ak")" 2>/dev/null || echo root:root)" "$ak" 2>/dev/null || true
  fi
done

# ------------------------------------------------------------
# 4. Cron review
# ------------------------------------------------------------
log "\n===== CRON REVIEW ====="

log "\n[*] /etc/crontab"
[[ -f /etc/crontab ]] && nl -ba /etc/crontab | tee -a "$LOG_FILE"

for d in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
  if [[ -d "$d" ]]; then
    log "\n[*] Listing $d"
    find "$d" -maxdepth 1 -type f -printf "%p\n" | tee -a "$LOG_FILE"
  fi
done

for user in $(cut -d: -f1 /etc/passwd); do
  crontab -u "$user" -l >/tmp/.crontab_"$user" 2>/dev/null || true
  if [[ -s /tmp/.crontab_"$user" ]]; then
    log "\n[*] Crontab for $user"
    nl -ba /tmp/.crontab_"$user" | tee -a "$LOG_FILE"
  fi
done
rm -f /tmp/.crontab_* 2>/dev/null || true

# Heuristic quarantine: clearly malicious cron entries
for f in /etc/crontab /etc/cron.d/*; do
  [[ -f "$f" ]] || continue
  if grep -Eqi '(/dev/tcp/|nc[[:space:]].*-e|bash[[:space:]].*-i|curl[[:space:]].*\|[[:space:]]*bash|wget[[:space:]].*\|[[:space:]]*bash)' "$f"; then
    log "[!] Suspicious cron file detected: $f"
    move_quarantine "$f"
  fi
done

# ------------------------------------------------------------
# 5. rc.local and profile persistence
# ------------------------------------------------------------
log "\n===== STARTUP FILE REVIEW ====="

for f in /etc/rc.local /etc/profile /root/.bashrc /root/.profile /home/*/.bashrc /home/*/.profile /etc/profile.d/*; do
  [[ -f "$f" ]] || continue
  if grep -Eqi '(/dev/tcp/|nc[[:space:]].*-e|bash[[:space:]].*-i|curl[[:space:]].*\|[[:space:]]*bash|wget[[:space:]].*\|[[:space:]]*bash)' "$f"; then
    log "[!] Suspicious startup persistence found in $f"
    backup="$QUAR_DIR$(echo "$f" | sed 's#/#_#g').bak"
    cp -a "$f" "$backup" 2>/dev/null || true
    sed -i '/\/dev\/tcp\|nc .* -e\|bash .* -i\|curl .*|.*bash\|wget .*|.*bash/d' "$f" || true
  fi
done

# ------------------------------------------------------------
# 6. Systemd persistence review
# ------------------------------------------------------------
log "\n===== SYSTEMD REVIEW ====="

mkdir -p "$QUAR_DIR/systemd_units"

for dir in /etc/systemd/system /usr/local/lib/systemd/system; do
  [[ -d "$dir" ]] || continue
  find "$dir" -maxdepth 1 -type f \( -name "*.service" -o -name "*.timer" \) | while read -r unit; do
    log "[*] Inspecting unit: $unit"
    systemctl cat "$(basename "$unit")" >>"$LOG_FILE" 2>&1 || true

    if grep -Eqi '(/dev/tcp/|nc[[:space:]].*-e|bash[[:space:]].*-i|curl[[:space:]].*\|[[:space:]]*bash|wget[[:space:]].*\|[[:space:]]*bash)' "$unit"; then
      log "[!] Suspicious systemd unit: $unit"
      systemctl disable --now "$(basename "$unit")" 2>/dev/null || true
      move_quarantine "$unit"
    fi
  done
done

systemctl daemon-reload || true

# ------------------------------------------------------------
# 7. SUID review
# ------------------------------------------------------------
log "\n===== SUID REVIEW ====="

KNOWN_SAFE_REGEX='^(/usr/bin/passwd|/usr/bin/su|/usr/bin/sudo|/usr/bin/mount|/usr/bin/umount|/usr/bin/chsh|/usr/bin/chfn|/usr/bin/newgrp|/usr/bin/gpasswd|/usr/lib/openssh/ssh-keysign|/usr/libexec/openssh/ssh-keysign|/usr/bin/pkexec)$'

find / -xdev -perm -4000 -type f 2>/dev/null | sort | while read -r suidfile; do
  log "[*] SUID: $suidfile"
  if [[ ! "$suidfile" =~ $KNOWN_SAFE_REGEX ]]; then
    log "[?] Uncommon SUID found: $suidfile"
    chmod u-s "$suidfile" 2>/dev/null || true
  fi
done

# ------------------------------------------------------------
# 8. Web shell review
# ------------------------------------------------------------
if [[ "$ROLE" == "web" ]]; then
  log "\n===== WEB ROOT REVIEW ====="
  WEBROOTS=("/var/www/html" "/srv/www" "/usr/share/nginx/html")
  for wr in "${WEBROOTS[@]}"; do
    [[ -d "$wr" ]] || continue
    log "[*] Reviewing web root: $wr"
    find "$wr" -type f \( -name "*.php" -o -name "*.phtml" -o -name "*.jsp" -o -name "*.aspx" -o -name "*.sh" \) 2>/dev/null | while read -r wf; do
      if grep -Eqi '(base64_decode\s*\(|system\s*\(|shell_exec\s*\(|passthru\s*\(|exec\s*\(|assert\s*\(|eval\s*\(|cmd=|/bin/sh|/bin/bash|nc[[:space:]])' "$wf"; then
        log "[!] Suspicious web file: $wf"
        move_quarantine "$wf"
      fi
    done
  done
fi

# ------------------------------------------------------------
# 9. Listening port review
# ------------------------------------------------------------
log "\n===== LISTENING PORT REVIEW ====="

mapfile -t listening_ports < <(ss -lntupH 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | sort -u)

for port in "${listening_ports[@]:-}"; do
  skip=0
  for req in "${REQ_PORTS[@]}"; do
    if [[ "$port" == "$req" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" -eq 0 ]]; then
    log "[?] Non-required listening port detected: $port"
    ss -lntup "( sport = :$port )" 2>/dev/null | tee -a "$LOG_FILE" || true
  fi
done

# ------------------------------------------------------------
# 10. Fix common file perms
# ------------------------------------------------------------
log "\n===== PERMISSION RESET ====="

chmod 644 /etc/passwd /etc/group 2>/dev/null || true
if [[ $is_debian -eq 1 ]]; then
  chown root:shadow /etc/shadow /etc/gshadow 2>/dev/null || true
  chmod 640 /etc/shadow /etc/gshadow 2>/dev/null || true
else
  chown root:root /etc/shadow /etc/gshadow 2>/dev/null || true
  chmod 000 /etc/shadow /etc/gshadow 2>/dev/null || true
fi
chmod 440 /etc/sudoers 2>/dev/null || true

for d in /root/.ssh /home/*/.ssh; do
  [[ -d "$d" ]] || continue
  chmod 700 "$d" 2>/dev/null || true
done

for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [[ -f "$f" ]] || continue
  chmod 600 "$f" 2>/dev/null || true
done

# ------------------------------------------------------------
# 11. Ensure cron/at restrictions
# ------------------------------------------------------------
log "\n===== CRON / AT RESTRICTIONS ====="
echo root >/etc/cron.allow
rm -f /etc/cron.deny
echo root >/etc/at.allow
rm -f /etc/at.deny
chmod 600 /etc/cron.allow /etc/at.allow 2>/dev/null || true

# ------------------------------------------------------------
# 12. Restart required services carefully
# ------------------------------------------------------------
log "\n===== SERVICE VERIFICATION ====="

if [[ $is_debian -eq 1 ]]; then
  systemctl restart ssh || true
else
  systemctl restart sshd || true
fi

case "$ROLE" in
  web)
    systemctl restart apache2 2>/dev/null || systemctl restart httpd 2>/dev/null || true
    ;;
  db)
    systemctl restart postgresql 2>/dev/null || true
    ;;
  dns)
    systemctl restart named 2>/dev/null || systemctl restart bind9 2>/dev/null || true
    ;;
  smb)
    systemctl restart smb 2>/dev/null || systemctl restart smbd 2>/dev/null || true
    systemctl restart nmb 2>/dev/null || true
    ;;
  backup)
    # ssh already restarted
    ;;
esac

log "\n[*] Final listening ports:"
ss -tulpn | tee -a "$LOG_FILE"

log "\n[*] Final failed units:"
systemctl --failed | tee -a "$LOG_FILE" || true

log "\n[+] blue_recover complete"
log "[+] Review the log: $LOG_FILE"
log "[+] Review quarantine: $QUAR_DIR"
log "[+] Next step: run your role-specific hardening script"
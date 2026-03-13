#!/usr/bin/env bash
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

INIT_MODE=0
SAVE_MODE=0
ROLE=""

for arg in "$@"; do
  case "$arg" in
    --init) INIT_MODE=1 ;;
    --save) SAVE_MODE=1 ;;
    web|db|dns|smb|backup) ROLE="$arg" ;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "Usage:"
  echo "  sudo ./blue_monitor.sh --init <web|db|dns|smb|backup>"
  echo "  sudo ./blue_monitor.sh <web|db|dns|smb|backup> [--save]"
  exit 1
fi

BASE_DIR="/root/.blue_monitor_baseline/$ROLE"
TMP_DIR="$(mktemp -d)"
HOST="$(hostname)"
STAMP="$(date +%F_%H-%M-%S)"
REPORT="/root/blue_monitor_${HOST}_${STAMP}.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

say() {
  local msg="${1:-}"
  echo -e "$msg"
  if [[ $SAVE_MODE -eq 1 ]]; then
    echo -e "$msg" >> "$REPORT"
  fi
}

safe_copy() {
  local src="${1:-}"
  local dst="${2:-}"
  [[ -n "$src" && -n "$dst" && -f "$src" ]] && cp "$src" "$dst" 2>/dev/null || true
}

collect() {
  awk -F: '{print $1 ":" $3 ":" $6 ":" $7}' /etc/passwd 2>/dev/null | sort -u > "$TMP_DIR/passwd_users.txt" || true
  awk -F: '$3 == 0 {print $1}' /etc/passwd 2>/dev/null | sort -u > "$TMP_DIR/uid0_users.txt" || true
  cat /etc/group 2>/dev/null | sort -u > "$TMP_DIR/groups.txt" || true

  : > "$TMP_DIR/authorized_keys_inventory.txt"
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "$f" ]] || continue
    sha256sum "$f" >> "$TMP_DIR/authorized_keys_inventory.txt" 2>/dev/null || true
  done
  sort -u "$TMP_DIR/authorized_keys_inventory.txt" -o "$TMP_DIR/authorized_keys_inventory.txt" 2>/dev/null || true

  : > "$TMP_DIR/cron_inventory.txt"
  [[ -f /etc/crontab ]] && sha256sum /etc/crontab >> "$TMP_DIR/cron_inventory.txt" 2>/dev/null || true
  for f in /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.weekly/* /etc/cron.monthly/*; do
    [[ -f "$f" ]] || continue
    sha256sum "$f" >> "$TMP_DIR/cron_inventory.txt" 2>/dev/null || true
  done

  while IFS= read -r u; do
    tmpf="/tmp/.cron_${u}_$$"
    crontab -u "$u" -l > "$tmpf" 2>/dev/null || true
    if [[ -s "$tmpf" ]]; then
      sha256sum "$tmpf" 2>/dev/null | sed "s|$tmpf|user_crontab:$u|" >> "$TMP_DIR/cron_inventory.txt" || true
    fi
    rm -f "$tmpf"
  done < <(cut -d: -f1 /etc/passwd 2>/dev/null || true)

  sort -u "$TMP_DIR/cron_inventory.txt" -o "$TMP_DIR/cron_inventory.txt" 2>/dev/null || true

  : > "$TMP_DIR/systemd_units.txt"
  for dir in /etc/systemd/system /usr/local/lib/systemd/system; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 1 -type f \( -name "*.service" -o -name "*.timer" \) 2>/dev/null | while read -r f; do
      sha256sum "$f" 2>/dev/null || true
    done >> "$TMP_DIR/systemd_units.txt"
  done
  sort -u "$TMP_DIR/systemd_units.txt" -o "$TMP_DIR/systemd_units.txt" 2>/dev/null || true

  find / -xdev -perm -4000 -type f 2>/dev/null | sort > "$TMP_DIR/suid_files.txt" || true
  ss -lntupH 2>/dev/null | awk '{print $1 "|" $5 "|" $7}' | sort -u > "$TMP_DIR/listening_ports.txt" || true
  systemctl --failed --no-pager --plain 2>/dev/null > "$TMP_DIR/failed_services.txt" || true
  ps -eo pid,user,cmd --no-headers 2>/dev/null | grep -Ei 'nc .* -e|bash -i|/dev/tcp/|curl .*\|.*bash|wget .*\|.*bash|python.*http.server|socat|perl .*socket' > "$TMP_DIR/suspicious_processes.txt" || true

  if [[ "$ROLE" == "web" ]]; then
    : > "$TMP_DIR/webroot_files.txt"
    for wr in /var/www/html /srv/www /usr/share/nginx/html; do
      [[ -d "$wr" ]] || continue
      find "$wr" -type f 2>/dev/null | sort | while read -r f; do
        sha256sum "$f" 2>/dev/null || true
      done >> "$TMP_DIR/webroot_files.txt"
    done
    sort -u "$TMP_DIR/webroot_files.txt" -o "$TMP_DIR/webroot_files.txt" 2>/dev/null || true
  fi
}

show_diff_if_changed() {
  local base="${1:-}"
  local current="${2:-}"
  local label="${3:-Unnamed check}"

  if [[ -z "$base" || -z "$current" ]]; then
    say "[ALERT] $label check missing arguments"
    return
  fi

  if [[ ! -f "$base" ]]; then
    say "[ALERT] Missing baseline file for $label: $base"
    return
  fi

  if [[ ! -f "$current" ]]; then
    say "[ALERT] Missing current file for $label: $current"
    return
  fi

  if ! diff -u "$base" "$current" > /tmp/.blue_diff_$$ 2>/dev/null; then
    say "\n[ALERT] $label changed"
    cat /tmp/.blue_diff_$$ 2>/dev/null || true
  else
    say "[OK] No change: $label"
  fi
  rm -f /tmp/.blue_diff_$$
}

role_sanity() {
  case "$ROLE" in
    web)
      ss -lntup 2>/dev/null | grep -E ':80 |:443 ' >/dev/null 2>&1 && say "[OK] Web ports present" || say "[ALERT] Web ports missing"
      ;;
    db)
      ss -lntup 2>/dev/null | grep -E ':5432 ' >/dev/null 2>&1 && say "[OK] DB port present" || say "[ALERT] DB port missing"
      ;;
    dns)
      ss -lntup 2>/dev/null | grep -E ':53 ' >/dev/null 2>&1 && say "[OK] DNS port present" || say "[ALERT] DNS port missing"
      ;;
    smb)
      ss -lntup 2>/dev/null | grep -E ':139 |:445 ' >/dev/null 2>&1 && say "[OK] SMB ports present" || say "[ALERT] SMB ports missing"
      ;;
    backup)
      ss -lntup 2>/dev/null | grep -E ':22 ' >/dev/null 2>&1 && say "[OK] SSH port present" || say "[ALERT] SSH port missing"
      ;;
  esac
}

say "===== BLUE MONITOR START ====="
say "Host: $HOST"
say "Role: $ROLE"
say "Mode: $([[ $INIT_MODE -eq 1 ]] && echo init || echo compare)"
say

collect

if [[ $INIT_MODE -eq 1 ]]; then
  mkdir -p "$BASE_DIR"
  safe_copy "$TMP_DIR/passwd_users.txt"              "$BASE_DIR/passwd_users.txt"
  safe_copy "$TMP_DIR/uid0_users.txt"                "$BASE_DIR/uid0_users.txt"
  safe_copy "$TMP_DIR/groups.txt"                    "$BASE_DIR/groups.txt"
  safe_copy "$TMP_DIR/authorized_keys_inventory.txt" "$BASE_DIR/authorized_keys_inventory.txt"
  safe_copy "$TMP_DIR/cron_inventory.txt"            "$BASE_DIR/cron_inventory.txt"
  safe_copy "$TMP_DIR/systemd_units.txt"             "$BASE_DIR/systemd_units.txt"
  safe_copy "$TMP_DIR/suid_files.txt"                "$BASE_DIR/suid_files.txt"
  safe_copy "$TMP_DIR/listening_ports.txt"           "$BASE_DIR/listening_ports.txt"
  if [[ "$ROLE" == "web" ]]; then
    safe_copy "$TMP_DIR/webroot_files.txt"           "$BASE_DIR/webroot_files.txt"
  fi
  say "[+] Baseline initialized for $ROLE on $HOST"
  say "===== BLUE MONITOR END ====="
  exit 0
fi

if [[ ! -d "$BASE_DIR" ]]; then
  say "[-] No baseline found for $ROLE"
  say "[*] Run: sudo ./blue_monitor.sh --init $ROLE"
  say "===== BLUE MONITOR END ====="
  exit 1
fi

say "===== BASELINE COMPARISON ====="
show_diff_if_changed "$BASE_DIR/passwd_users.txt"              "$TMP_DIR/passwd_users.txt"              "Users"
show_diff_if_changed "$BASE_DIR/uid0_users.txt"                "$TMP_DIR/uid0_users.txt"                "UID 0 users"
show_diff_if_changed "$BASE_DIR/groups.txt"                    "$TMP_DIR/groups.txt"                    "Groups"
show_diff_if_changed "$BASE_DIR/authorized_keys_inventory.txt" "$TMP_DIR/authorized_keys_inventory.txt" "authorized_keys"
show_diff_if_changed "$BASE_DIR/cron_inventory.txt"            "$TMP_DIR/cron_inventory.txt"            "Cron inventory"
show_diff_if_changed "$BASE_DIR/systemd_units.txt"             "$TMP_DIR/systemd_units.txt"             "Systemd units"
show_diff_if_changed "$BASE_DIR/suid_files.txt"                "$TMP_DIR/suid_files.txt"                "SUID files"
show_diff_if_changed "$BASE_DIR/listening_ports.txt"           "$TMP_DIR/listening_ports.txt"           "Listening ports"

if [[ "$ROLE" == "web" ]]; then
  show_diff_if_changed "$BASE_DIR/webroot_files.txt" "$TMP_DIR/webroot_files.txt" "Webroot files"
fi

say "\n===== RUNTIME CHECKS ====="
if [[ -s "$TMP_DIR/suspicious_processes.txt" ]]; then
  say "\n[ALERT] Suspicious process patterns:"
  cat "$TMP_DIR/suspicious_processes.txt" 2>/dev/null || true
else
  say "[OK] No suspicious process patterns"
fi

if [[ -s "$TMP_DIR/failed_services.txt" ]]; then
  say "\n[ALERT] Failed services:"
  cat "$TMP_DIR/failed_services.txt" 2>/dev/null || true
else
  say "[OK] No failed services"
fi

say
role_sanity

if [[ $SAVE_MODE -eq 1 ]]; then
  say "\n[+] Saved report to $REPORT"
fi

say "\n===== BLUE MONITOR END ====="
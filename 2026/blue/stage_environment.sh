#!/usr/bin/env bash
set -euo pipefail

# NCAE environment staging wrapper
#
# What this does:
#  1) Ask Ubuntu or Rocky
#  2) Ask service role
#  3) Ask whether this is the backup server
#  4) Ensure/download needed scripts
#  5) Run blue_recover.sh
#  6) Run the appropriate harden script
#  7) Initialize blue_monitor baseline
#  8) Install and run chkrootkit + linPEAS
#

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./stage_environment.sh"
  exit 1
fi

WORKDIR="/opt/ncae_stage"
LOGROOT="/root/stage_logs"
STAMP="$(date +%F_%H-%M-%S)"
LOGDIR="$LOGROOT/$STAMP"
mkdir -p "$WORKDIR" "$LOGDIR"
chmod 700 "$LOGROOT" "$LOGDIR"


UBUNTU_HARDEN_URL="https://raw.githubusercontent.com/NJITICC/NCAE_CyberGames_Prep/main/2026/blue/ubuntu_harden.sh"
ROCKY_HARDEN_URL="https://raw.githubusercontent.com/NJITICC/NCAE_CyberGames_Prep/main/2026/blue/rocky_harden.sh"
BLUE_RECOVER_URL="https://raw.githubusercontent.com/NJITICC/NCAE_CyberGames_Prep/main/2026/blue/blue_recover.sh"
BLUE_MONITOR_URL="https://raw.githubusercontent.com/NJITICC/NCAE_CyberGames_Prep/main/2026/blue/blue_monitor.sh"
BACKUP_CLIENT_URL="https://raw.githubusercontent.com/NJITICC/NCAE_CyberGames_Prep/main/2026/backups/backup_client.sh"
BACKUP_MANAGER_URL="https://raw.githubusercontent.com/NJITICC/NCAE_CyberGames_Prep/main/2026/backups/backup_manager.sh"
LINPEAS_URL="https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh"

log() {
  echo -e "$1" | tee -a "$LOGDIR/stage_environment.log"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

fetch_url() {
  local url="$1"
  local out="$2"

  if have_cmd curl; then
    curl -fsSL "$url" -o "$out"
  elif have_cmd wget; then
    wget -qO "$out" "$url"
  else
    return 1
  fi
}

install_download_tools() {
  if have_cmd curl || have_cmd wget; then
    return 0
  fi

  if have_cmd apt-get; then
    apt-get update
    apt-get install -y curl wget
  elif have_cmd dnf; then
    dnf install -y curl wget
  else
    log "[-] Could not install curl/wget automatically. Unsupported package manager."
    exit 1
  fi
}

prompt_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local reply=""

  while true; do
    echo >&2
    echo "$prompt" >&2
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt" >&2
      ((i++))
    done
    read -r -p "Enter choice: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
      echo "${options[$((reply-1))]}"
      return 0
    fi
    echo "Invalid selection. Try again." >&2
  done
}

prompt_yes_no() {
  local prompt="$1"
  local reply=""
  while true; do
    read -r -p "$prompt [y/n]: " reply
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

ensure_script() {
  local filename="$1"
  local configured_url="$2"
  local destination="$WORKDIR/$filename"
  local source_local=""
  local supplied_url=""

  if [[ -f "$destination" ]]; then
    chmod +x "$destination" || true
    log "[=] Using existing $destination"
    return 0
  fi

  for candidate in "/opt/ncae/$filename" "./$filename" "/root/$filename"; do
    if [[ -f "$candidate" ]]; then
      source_local="$candidate"
      break
    fi
  done

  if [[ -n "$source_local" ]]; then
    cp "$source_local" "$destination"
    chmod +x "$destination"
    log "[+] Copied local $source_local -> $destination"
    return 0
  fi

  install_download_tools

  if [[ -z "$configured_url" ]]; then
    echo
    read -r -p "Enter URL for $filename: " supplied_url
  else
    supplied_url="$configured_url"
  fi

  if [[ -z "$supplied_url" ]]; then
    log "[-] No URL supplied for $filename"
    exit 1
  fi

  if fetch_url "$supplied_url" "$destination"; then
    chmod +x "$destination"
    log "[+] Downloaded $filename -> $destination"
  else
    log "[-] Failed to download $filename from $supplied_url"
    exit 1
  fi
}

install_chkrootkit() {
  if have_cmd chkrootkit; then
    log "[=] chkrootkit already installed"
    return 0
  fi

  if have_cmd apt-get; then
    apt-get update
    apt-get install -y chkrootkit || true
  elif have_cmd dnf; then
    dnf install -y epel-release || true
    dnf install -y chkrootkit || true
  fi

  if have_cmd chkrootkit; then
    log "[+] chkrootkit installed"
  else
    log "[!] chkrootkit could not be installed automatically on this host"
  fi
}

install_linpeas() {
  local out="$WORKDIR/linpeas.sh"
  if [[ -f "$out" ]]; then
    chmod +x "$out" || true
    log "[=] linpeas already present at $out"
    return 0
  fi

  install_download_tools
  if fetch_url "$LINPEAS_URL" "$out"; then
    chmod +x "$out"
    log "[+] linpeas downloaded to $out"
  else
    log "[!] Failed to download linpeas from $LINPEAS_URL"
  fi
}

run_and_log() {
  local name="$1"
  shift
  local outfile="$LOGDIR/${name}.log"

  log "\n===== Running: $name ====="
  (
    echo "[COMMAND] $*"
    echo "[START] $(date)"
    "$@"
    rc=$?
    echo "[END] $(date)"
    echo "[RC] $rc"
    exit $rc
  ) 2>&1 | tee "$outfile"
  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    log "[!] $name exited with code $rc"
  else
    log "[+] $name completed successfully"
  fi
  return 0
}

run_and_log_allow_fail() {
  local name="$1"
  shift
  local outfile="$LOGDIR/${name}.log"

  log "\n===== Running: $name ====="
  (
    echo "[COMMAND] $*"
    echo "[START] $(date)"
    "$@"
    rc=$?
    echo "[END] $(date)"
    echo "[RC] $rc"
    exit $rc
  ) 2>&1 | tee "$outfile" || true
  log "[+] $name finished"
  return 0
}

# ------------------------------
# Auto-detect OS
# ------------------------------
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "$ID" in
    ubuntu|debian) OS_CHOICE="ubuntu" ;;
    rocky|rhel|centos|almalinux) OS_CHOICE="rocky" ;;
    *) OS_CHOICE="$(prompt_choice "Could not detect OS. Select manually" "ubuntu" "rocky")" ;;
  esac
  log "[+] Auto-detected OS: $OS_CHOICE ($ID)"
else
  OS_CHOICE="$(prompt_choice "Select operating system" "ubuntu" "rocky")"
fi

# ------------------------------
# Auto-detect role from hostname
# ------------------------------
HOSTNAME_LOWER=$(hostname | tr '[:upper:]' '[:lower:]')
ROLE=""

if   echo "$HOSTNAME_LOWER" | grep -q "web";    then ROLE="web"
elif echo "$HOSTNAME_LOWER" | grep -q "db";     then ROLE="db"
elif echo "$HOSTNAME_LOWER" | grep -q "dns";    then ROLE="dns"
elif echo "$HOSTNAME_LOWER" | grep -q "ftp" || \
     echo "$HOSTNAME_LOWER" | grep -q "smb" || \
     echo "$HOSTNAME_LOWER" | grep -q "shell";  then ROLE="smb"
elif echo "$HOSTNAME_LOWER" | grep -q "backup"; then ROLE="backup"
fi

if [[ -n "$ROLE" ]]; then
  log "[+] Auto-detected role: $ROLE (from hostname: $(hostname))"
else
  ROLE="$(prompt_choice "Could not detect role. Select manually" "web" "db" "dns" "smb" "backup")"
fi

# Determine if this is the backup server
IS_BACKUP_SERVER=0
if [[ "$ROLE" == "backup" ]]; then
  IS_BACKUP_SERVER=1
fi

log "[*] OS: $OS_CHOICE"
log "[*] Role: $ROLE"
log "[*] Backup server: $([[ $IS_BACKUP_SERVER -eq 1 ]] && echo yes || echo no)"
log "[*] Workdir: $WORKDIR"
log "[*] Logs: $LOGDIR"

# ------------------------------
# Ensure required files
# ------------------------------
ensure_script "blue_recover.sh" "$BLUE_RECOVER_URL"
ensure_script "blue_monitor.sh" "$BLUE_MONITOR_URL"

case "$OS_CHOICE" in
  ubuntu)
    ensure_script "ubuntu_harden.sh" "$UBUNTU_HARDEN_URL"
    HARDEN_SCRIPT="$WORKDIR/ubuntu_harden.sh"
    ;;
  rocky)
    ensure_script "rocky_harden.sh" "$ROCKY_HARDEN_URL"
    HARDEN_SCRIPT="$WORKDIR/rocky_harden.sh"
    ;;
esac

ensure_script "backup_client.sh" "$BACKUP_CLIENT_URL"
if [[ $IS_BACKUP_SERVER -eq 1 ]]; then
  ensure_script "backup_manager.sh" "$BACKUP_MANAGER_URL"
fi

# Optional: place backup scripts on Desktop too for convenience
if [[ -d /root/Desktop ]]; then
  cp -f "$WORKDIR/backup_client.sh" /root/Desktop/ 2>/dev/null || true
  [[ $IS_BACKUP_SERVER -eq 1 ]] && cp -f "$WORKDIR/backup_manager.sh" /root/Desktop/ 2>/dev/null || true
fi

# ------------------------------
# Stage order
# ------------------------------
run_and_log "01_blue_recover" "$WORKDIR/blue_recover.sh" "$ROLE"
run_and_log "02_hardening" "$HARDEN_SCRIPT" "$ROLE"
run_and_log "03_blue_monitor_init" "$WORKDIR/blue_monitor.sh" --init "$ROLE"

# ------------------------------
# Rootkit / privesc tooling
# ------------------------------
install_chkrootkit
install_linpeas

if have_cmd chkrootkit; then
  run_and_log_allow_fail "04_chkrootkit" chkrootkit
fi

if [[ -x "$WORKDIR/linpeas.sh" ]]; then
  run_and_log_allow_fail "05_linpeas" timeout 900 bash "$WORKDIR/linpeas.sh" -a
fi

# ------------------------------
# Create protected /root/scripts
# ------------------------------
log "\n===== CREATING PROTECTED SCRIPTS DIR ====="
SCRIPTS_DIR="/root/scripts"

# Remove immutable flag if it was set previously (idempotent re-run)
chattr -i "$SCRIPTS_DIR" 2>/dev/null || true

mkdir -p "$SCRIPTS_DIR"

# Copy all blue team scripts into /root/scripts
cp -f "$WORKDIR/blue_recover.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
cp -f "$WORKDIR/blue_monitor.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
cp -f "$WORKDIR/backup_client.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
[[ -f "$WORKDIR/ubuntu_harden.sh" ]] && cp -f "$WORKDIR/ubuntu_harden.sh" "$SCRIPTS_DIR/harden.sh" 2>/dev/null || true
[[ -f "$WORKDIR/rocky_harden.sh" ]] && cp -f "$WORKDIR/rocky_harden.sh" "$SCRIPTS_DIR/harden.sh" 2>/dev/null || true
[[ $IS_BACKUP_SERVER -eq 1 && -f "$WORKDIR/backup_manager.sh" ]] && cp -f "$WORKDIR/backup_manager.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
[[ -f "$WORKDIR/linpeas.sh" ]] && cp -f "$WORKDIR/linpeas.sh" "$SCRIPTS_DIR/" 2>/dev/null || true

chmod 700 "$SCRIPTS_DIR"
chmod 755 "$SCRIPTS_DIR"/*.sh 2>/dev/null || true
chown -R root:root "$SCRIPTS_DIR"

# Lock the directory with chattr so red team can't tamper with it
chattr +i "$SCRIPTS_DIR"
log "[+] /root/scripts created and protected with chattr +i"
log "[+] To modify scripts later: chattr -i /root/scripts"

log "\n===== COMPLETE ====="
log "[+] Environment staging finished"
log "[+] Main log: $LOGDIR/stage_environment.log"
log "[+] blue_recover log: $LOGDIR/01_blue_recover.log"
log "[+] hardening log: $LOGDIR/02_hardening.log"
log "[+] baseline init log: $LOGDIR/03_blue_monitor_init.log"
[[ -f "$LOGDIR/04_chkrootkit.log" ]] && log "[+] chkrootkit log: $LOGDIR/04_chkrootkit.log"
[[ -f "$LOGDIR/05_linpeas.log" ]] && log "[+] linpeas log: $LOGDIR/05_linpeas.log"

exit 0
#!/bin/bash

set -u

CONFIG="/etc/ncae_backup.conf"
BACKUP_ROOT="/backups"
TEAM=""
ROLE=""
BACKUP_SERVER_IP=""

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Run with sudo"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG" ]; then
        source "$CONFIG"
        BACKUP_SERVER_IP="192.168.$TEAM.15"
    fi
}

save_config() {
cat <<EOF > "$CONFIG"
TEAM=$TEAM
ROLE=$ROLE
EOF
chmod 600 "$CONFIG"
}

install_packages() {
if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y rsync openssh-client sshpass
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rsync openssh-clients sshpass policycoreutils-python-utils policycoreutils
else
    echo "Unsupported package manager"
    exit 1
fi
}

ensure_user() {
    local username="$1"
    if ! id "$username" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$username"
        echo "Set password for $username"
        passwd "$username"
    fi
    mkdir -p "/home/$username/.ssh"
    touch "/home/$username/.ssh/authorized_keys"
    chown -R "$username:$username" "/home/$username/.ssh"
    chmod 700 "/home/$username/.ssh"
    chmod 600 "/home/$username/.ssh/authorized_keys"
}

wait_for_key_and_lock() {
    local username="$1"
    local auth="/home/$username/.ssh/authorized_keys"
    echo "Waiting for SSH key..."
    while true; do
        if grep -q "ssh-" "$auth" 2>/dev/null; then
            echo "SSH key detected for $username"
            passwd -l "$username" >/dev/null 2>&1 || true
            break
        fi
        sleep 5
    done
}

############################
# DIRECTORY PERMISSIONS
############################

ensure_service_dirs() {
    local service="$1"
    mkdir -p "$BACKUP_ROOT/latest/$service"
    mkdir -p "$BACKUP_ROOT/archive/$service"
    chown -R backupuser:backupuser "$BACKUP_ROOT"
    chmod 755 "$BACKUP_ROOT"
    chmod 755 "$BACKUP_ROOT/latest"
    chmod 755 "$BACKUP_ROOT/archive"
    chmod 750 "$BACKUP_ROOT/latest/$service"
    chmod 750 "$BACKUP_ROOT/archive/$service"
}

ensure_backup_server_dirs() {
    mkdir -p "$BACKUP_ROOT/latest/web" "$BACKUP_ROOT/latest/dns" "$BACKUP_ROOT/latest/db" "$BACKUP_ROOT/latest/smb"
    mkdir -p "$BACKUP_ROOT/archive/web" "$BACKUP_ROOT/archive/dns" "$BACKUP_ROOT/archive/db" "$BACKUP_ROOT/archive/smb"
    chmod 755 "$BACKUP_ROOT" "$BACKUP_ROOT/latest" "$BACKUP_ROOT/archive"
}

apply_backup_server_permissions() {
    if id backupuser >/dev/null 2>&1; then
        chown -R backupuser:backupuser "$BACKUP_ROOT"
    fi
    if id secondary_backupuser >/dev/null 2>&1; then
        chgrp -R secondary_backupuser "$BACKUP_ROOT" 2>/dev/null || true
        chmod g+rwx "$BACKUP_ROOT" "$BACKUP_ROOT/latest" "$BACKUP_ROOT/archive"
        chmod -R g+rwX "$BACKUP_ROOT/latest" "$BACKUP_ROOT/archive"
    fi
    chmod 755 "$BACKUP_ROOT" "$BACKUP_ROOT/latest" "$BACKUP_ROOT/archive"
}

############################
# BACKUP HELPERS
############################

archive_latest() {
    local service="$1"
    local latest="$BACKUP_ROOT/latest/$service"
    local archive="$BACKUP_ROOT/archive/$service"
    local ts=$(date +"%F_%H-%M-%S")
    if [ -d "$latest" ] && [ "$(find "$latest" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        mkdir -p "$archive/$ts"
        shopt -s dotglob nullglob
        mv "$latest"/* "$archive/$ts"/
        shopt -u dotglob nullglob
        echo "Archived previous backup -> $archive/$ts"
    fi
}

clear_latest() {
    local service="$1"
    mkdir -p "$BACKUP_ROOT/latest/$service"
    shopt -s dotglob nullglob
    rm -rf "$BACKUP_ROOT/latest/$service"/*
    shopt -u dotglob nullglob
}

finalize_permissions() {
    local service="$1"
    chown -R backupuser:backupuser "$BACKUP_ROOT/latest/$service" 2>/dev/null || true
    find "$BACKUP_ROOT/latest/$service" -type d -exec chmod 750 {} \; 2>/dev/null || true
    find "$BACKUP_ROOT/latest/$service" -type f -exec chmod 640 {} \; 2>/dev/null || true
}

restart_if_exists() {
    local svc="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl restart "$svc" 2>/dev/null || true
    fi
}

############################
# BACKUPS
############################

prepare_web_backup() {
    echo "Preparing WEB backup"
    archive_latest web
    clear_latest web
    rsync -a /var/www/ "$BACKUP_ROOT/latest/web/www/"
    rsync -a /etc/apache2/ "$BACKUP_ROOT/latest/web/apache2/" 2>/dev/null || true
    finalize_permissions web
}

prepare_dns_backup() {
    echo "Preparing DNS backup"
    archive_latest dns
    clear_latest dns
    mkdir -p "$BACKUP_ROOT/latest/dns/etc_named"
    rsync -a /etc/named* "$BACKUP_ROOT/latest/dns/etc_named/" 2>/dev/null || true
    [ -d /var/named ] && rsync -a /var/named "$BACKUP_ROOT/latest/dns/"
    finalize_permissions dns
}

prepare_db_backup() {
    echo "Preparing PostgreSQL backup"
    archive_latest db
    clear_latest db
    sudo -u postgres pg_dumpall > "$BACKUP_ROOT/latest/db/db_backup.sql" 2>/dev/null || true
    [ -d /etc/postgresql ] && rsync -a /etc/postgresql/ "$BACKUP_ROOT/latest/db/postgresql/"
    finalize_permissions db
}

prepare_smb_backup() {
    echo "Preparing SMB backup"
    archive_latest smb
    clear_latest smb
    [ -d /etc/samba ] && rsync -a /etc/samba/ "$BACKUP_ROOT/latest/smb/samba/"
    [ -d /var/lib/samba ] && rsync -a /var/lib/samba/ "$BACKUP_ROOT/latest/smb/lib/"
    [ -d /mnt/files ] && rsync -a /mnt/files/ "$BACKUP_ROOT/latest/smb/files/"
    finalize_permissions smb
}

############################
# RESTORES
############################

restore_web() {
    echo "Restoring Apache"
    rsync -a --delete "$BACKUP_ROOT/latest/web/www/" /var/www/
    rsync -a --delete "$BACKUP_ROOT/latest/web/apache2/" /etc/apache2/ 2>/dev/null || true
    chown -R www-data:www-data /var/www 2>/dev/null || true
    find /var/www -type d -exec chmod 755 {} \; 2>/dev/null || true
    find /var/www -type f -exec chmod 644 {} \; 2>/dev/null || true
    restart_if_exists apache2
}

restore_dns() {
    echo "Restoring DNS (Rocky)"
    if [ -d "$BACKUP_ROOT/latest/dns/etc_named" ]; then
        # Tell rsync NOT to overwrite /etc directory permissions
        rsync -a --no-perms --no-owner --no-group "$BACKUP_ROOT/latest/dns/etc_named/" /etc/

        chown root:root /etc
        chmod 755 /etc

        chown -R root:named /etc/named* 2>/dev/null || true
        find /etc/named* -type d -exec chmod 750 {} \; 2>/dev/null || true
        find /etc/named* -type f -exec chmod 640 {} \; 2>/dev/null || true
    fi

    if [ -d "$BACKUP_ROOT/latest/dns/named" ]; then
        rsync -a --delete "$BACKUP_ROOT/latest/dns/named" /var/

        chown root:named /var/named 2>/dev/null || true
        chmod 775 /var/named 2>/dev/null || true

        chown -R root:named /var/named/* 2>/dev/null || true
        find /var/named -type d -exec chmod 770 {} \; 2>/dev/null || true
        find /var/named -type f -exec chmod 640 {} \; 2>/dev/null || true

        for dir in data dynamic slaves; do
            if [ -d "/var/named/$dir" ]; then
                chown -R named:named "/var/named/$dir" 2>/dev/null || true
                chmod -R 770 "/var/named/$dir" 2>/dev/null || true
            fi
        done
    fi

    restorecon -Rv /var/named /etc/named* 2>/dev/null || true
    restart_if_exists named
}

restore_db() {
    echo "Restoring PostgreSQL"
    rsync -a --delete "$BACKUP_ROOT/latest/db/postgresql/" /etc/postgresql/ 2>/dev/null || true
    chown -R postgres:postgres /etc/postgresql 2>/dev/null || true

    find /etc/postgresql -type d -exec chmod 755 {} \; 2>/dev/null || true
    find /etc/postgresql -type f -exec chmod 644 {} \; 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true
    restart_if_exists postgresql
    sleep 5

    if [ -f "$BACKUP_ROOT/latest/db/db_backup.sql" ]; then
        sudo -u postgres psql -f "$BACKUP_ROOT/latest/db/db_backup.sql" 2>/dev/null || true
    fi
    restart_if_exists postgresql
}

restore_smb() {
    echo "Restoring SMB"
    rsync -a --delete "$BACKUP_ROOT/latest/smb/samba/" /etc/samba/ 2>/dev/null || true
    rsync -a --delete "$BACKUP_ROOT/latest/smb/lib/" /var/lib/samba/ 2>/dev/null || true
    rsync -a --delete "$BACKUP_ROOT/latest/smb/files/" /mnt/files/ 2>/dev/null || true

    chmod 2777 /mnt/files 2>/dev/null || true
    chown -R root:root /mnt/files 2>/dev/null || true
    find /mnt/files -type f -exec chmod 0666 {} \; 2>/dev/null || true

    chown -R root:root /etc/samba /var/lib/samba 2>/dev/null || true
    find /etc/samba -type d -exec chmod 755 {} \; 2>/dev/null || true
    find /etc/samba -type f -exec chmod 644 {} \; 2>/dev/null || true

    mkdir -p /var/lib/samba/lock/msg.lock
    chmod 755 /var/lib/samba/lock
    chmod 755 /var/lib/samba/lock/msg.lock

    if [ ! -d /var/lib/samba/private ]; then
        mkdir -p /var/lib/samba/private
    fi

    if [ -d /var/lib/samba/private ]; then
        chown -R root:root /var/lib/samba/private 2>/dev/null || true
        chmod 700 /var/lib/samba/private 2>/dev/null || true
        find /var/lib/samba/private -type d -exec chmod 700 {} \; 2>/dev/null || true
    fi

    restorecon -Rv /var/lib/samba /etc/samba /mnt/files 2>/dev/null || true

    restart_if_exists smb
    restart_if_exists smbd
}

############################
# SECONDARY BACKUP
############################

secondary_generate_key() {
    if [ ! -f /home/secondary_backupuser/.ssh/id_rsa ]; then
        sudo -u secondary_backupuser ssh-keygen -t rsa -b 4096 -N "" -f /home/secondary_backupuser/.ssh/id_rsa
    else
        echo "SSH key already exists for secondary_backupuser"
    fi
}

secondary_install_key_on_primary() {
    echo
    echo "Installing secondary_backupuser public key onto backup server $BACKUP_SERVER_IP"
    sudo -u secondary_backupuser ssh-copy-id \
        -i /home/secondary_backupuser/.ssh/id_rsa.pub \
        "backupuser@$BACKUP_SERVER_IP"
}

secondary_pull_from_primary() {
    echo
    echo "Pulling /backups from primary backup server..."
    mkdir -p "$BACKUP_ROOT"
    chown -R secondary_backupuser:secondary_backupuser "$BACKUP_ROOT"
    chmod -R u+rwX "$BACKUP_ROOT"

    if ! sudo -u secondary_backupuser rsync -rltDz --delete \
        -e "ssh -i /home/secondary_backupuser/.ssh/id_rsa -o StrictHostKeyChecking=no" \
        "backupuser@$BACKUP_SERVER_IP:$BACKUP_ROOT/" \
        "$BACKUP_ROOT/"; then
        echo "WARNING: pull from primary failed"
        return 1
    fi

    chown -R secondary_backupuser:secondary_backupuser "$BACKUP_ROOT"
    chmod -R u+rwX "$BACKUP_ROOT"

    echo "Pull complete"
    return 0
}

secondary_restore_to_primary() {
    echo
    read -r -p "This will overwrite $BACKUP_ROOT on the primary backup server. Continue? (y/n): " CONFIRM1
    if [ "$CONFIRM1" != "y" ] && [ "$CONFIRM1" != "Y" ]; then
        echo "Cancelled"
        return 0
    fi

    read -r -p "Are you absolutely sure? (y/n): " CONFIRM2
    if [ "$CONFIRM2" != "y" ] && [ "$CONFIRM2" != "Y" ]; then
        echo "Cancelled"
        return 0
    fi

    echo
    echo "Restoring /backups from secondary to primary..."

    if ! sudo -u secondary_backupuser rsync -rltDz --delete \
        -e "ssh -i /home/secondary_backupuser/.ssh/id_rsa -o StrictHostKeyChecking=no" \
        "$BACKUP_ROOT/" \
        "backupuser@$BACKUP_SERVER_IP:$BACKUP_ROOT/"; then
        echo "WARNING: restore to primary failed"
        return 1
    fi

    echo "Restore to primary complete"
    return 0
}

############################
# MENUS & MAIN SETUP
############################

service_menu() {
    while true; do
        echo
        echo "1 Backup"
        echo "2 Restore"
        echo "3 Exit"
        read -r action
        case "$action" in
            1)
                case "$ROLE" in
                    web) prepare_web_backup ;;
                    dns) prepare_dns_backup ;;
                    db) prepare_db_backup ;;
                    smb) prepare_smb_backup ;;
                esac
                ;;
            2)
                case "$ROLE" in
                    web) restore_web ;;
                    dns) restore_dns ;;
                    db) restore_db ;;
                    smb) restore_smb ;;
                esac
                ;;
            3) exit 0 ;;
            *) echo "Invalid selection" ;;
        esac
    done
}

secondary_menu() {
    while true; do
        echo
        echo "Select action"
        echo "1) Pull /backups from primary backup server"
        echo "2) Restore /backups back to primary backup server"
        echo "3) Exit"
        read -r ACTION
        case "$ACTION" in
            1) secondary_pull_from_primary ;;
            2) secondary_restore_to_primary ;;
            3) exit 0 ;;
            *) echo "Invalid selection" ;;
        esac
    done
}

backup_server_menu() {
    while true; do
        echo
        echo "Select action"
        echo "1) Exit"
        read -r ACTION
        case "$ACTION" in
            1) exit 0 ;;
            *) echo "Invalid selection" ;;
        esac
    done
}

setup_backup_server_accounts() {
    ensure_user backupuser
    ensure_user secondary_backupuser
    ensure_backup_server_dirs
    cat <<EOF > /etc/sudoers.d/backup_rsync
backupuser ALL=(ALL) NOPASSWD:/usr/bin/rsync
secondary_backupuser ALL=(ALL) NOPASSWD:/usr/bin/rsync
EOF
    chmod 440 /etc/sudoers.d/backup_rsync
    apply_backup_server_permissions
}

main() {
    require_root
    load_config
    if [ -z "${ROLE:-}" ]; then
        echo "Select machine role"
        echo "1 Web"
        echo "2 DNS"
        echo "3 DB"
        echo "4 SMB"
        echo "5 Backup Server"
        echo "6 Secondary Backup Server"
        read -r sel
        case "$sel" in
            1) ROLE=web ;;
            2) ROLE=dns ;;
            3) ROLE=db ;;
            4) ROLE=smb ;;
            5) ROLE=backup ;;
            6) ROLE=secondary ;;
            *) echo "Invalid role"; exit 1 ;;
        esac
        read -r -p "Enter team number: " TEAM
        save_config
    fi

    BACKUP_SERVER_IP="192.168.$TEAM.15"
    install_packages

    case "$ROLE" in
        backup)
            echo "Checking backup users..."
            setup_backup_server_accounts
            echo "Backup server setup complete."
            backup_server_menu
            ;;
        secondary)
            echo "Checking secondary backup user..."
            ensure_user secondary_backupuser
            ensure_backup_server_dirs
            chown -R secondary_backupuser:secondary_backupuser "$BACKUP_ROOT"
            chmod -R u+rwX "$BACKUP_ROOT"
            secondary_generate_key
            secondary_install_key_on_primary
            passwd -l secondary_backupuser >/dev/null 2>&1 || true
            echo "Secondary backup server setup complete."
            secondary_menu
            ;;
        *)
            ensure_user backupuser
            ensure_service_dirs "$ROLE"
            wait_for_key_and_lock backupuser
            service_menu
            ;;
    esac
}

main
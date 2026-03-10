#!/bin/bash

set -u

BACKUP_ROOT="/backups"
TEAM_FILE="/etc/ncae_backup_team"

WEB_IP=""
DB_IP=""
DNS_IP=""
SMB_IP=""
BACKUP_IP=""

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Run with sudo"
        exit 1
    fi
}

install_packages() {
    echo
    echo "Installing required packages..."

    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y rsync sshpass openssh-client
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y rsync sshpass openssh-clients
    else
        echo "Unsupported package manager"
        exit 1
    fi
}

ensure_user() {
    local user_name="$1"

    if ! id "$user_name" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$user_name"
        echo
        echo "Set password for $user_name"
        passwd "$user_name"
    else
        echo "$user_name already exists"
    fi

    mkdir -p "/home/$user_name/.ssh"
    chown -R "$user_name:$user_name" "/home/$user_name/.ssh"
    chmod 700 "/home/$user_name/.ssh"

    touch "/home/$user_name/.ssh/known_hosts"
    chown "$user_name:$user_name" "/home/$user_name/.ssh/known_hosts"
    chmod 600 "/home/$user_name/.ssh/known_hosts"
}

ensure_keypair() {
    local user_name="$1"
    local key_path="/home/$user_name/.ssh/id_rsa"

    if [ ! -f "$key_path" ]; then
        sudo -u "$user_name" ssh-keygen -t rsa -b 4096 -N "" -f "$key_path"
    else
        echo "SSH key already exists for $user_name"
    fi
}

ensure_backup_dirs() {
    mkdir -p "$BACKUP_ROOT/latest/web" "$BACKUP_ROOT/latest/dns" "$BACKUP_ROOT/latest/db" "$BACKUP_ROOT/latest/smb"
    mkdir -p "$BACKUP_ROOT/archive/web" "$BACKUP_ROOT/archive/dns" "$BACKUP_ROOT/archive/db" "$BACKUP_ROOT/archive/smb"

    chown -R backupuser:backupuser "$BACKUP_ROOT"
    chmod 755 "$BACKUP_ROOT"
    chmod 755 "$BACKUP_ROOT/latest" "$BACKUP_ROOT/archive"
    chmod 750 "$BACKUP_ROOT/latest"/* "$BACKUP_ROOT/archive"/* 2>/dev/null || true
}

finalize_server_service_permissions() {
    local service="$1"
    local dir="$BACKUP_ROOT/latest/$service"

    chown -R backupuser:backupuser "$dir"
    find "$dir" -type d -exec chmod 750 {} \; 2>/dev/null || true
    find "$dir" -type f -exec chmod 640 {} \; 2>/dev/null || true
}

archive_server_service_latest() {
    local service="$1"
    local latest_dir="$BACKUP_ROOT/latest/$service"
    local archive_root="$BACKUP_ROOT/archive/$service"
    local ts

    ts=$(date +"%Y-%m-%d_%H-%M-%S")

    if [ -d "$latest_dir" ] && [ "$(find "$latest_dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        mkdir -p "$archive_root/$ts"
        shopt -s dotglob nullglob
        mv "$latest_dir"/* "$archive_root/$ts"/
        shopt -u dotglob nullglob
        echo "Moved existing server latest for $service to $archive_root/$ts"
    fi
}

clear_server_service_latest() {
    local service="$1"

    mkdir -p "$BACKUP_ROOT/latest/$service"
    shopt -s dotglob nullglob
    rm -rf "$BACKUP_ROOT/latest/$service"/*
    shopt -u dotglob nullglob
}

bootstrap_remote_key() {
    local local_user="$1"
    local remote_user="$2"
    local remote_ip="$3"
    local remote_password="$4"
    local pubkey_file="/home/$local_user/.ssh/id_rsa.pub"

    echo
    echo "Installing SSH key for $remote_user@$remote_ip using $local_user key"

    sudo -u "$local_user" ssh-keyscan -H "$remote_ip" >> "/home/$local_user/.ssh/known_hosts" 2>/dev/null || true

    if ! sshpass -p "$remote_password" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_ip" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
        echo "WARNING: could not prepare ~/.ssh on $remote_user@$remote_ip"
        return 1
    fi

    if ! sshpass -p "$remote_password" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_ip" \
        "grep -qxF '$(cat "$pubkey_file")' ~/.ssh/authorized_keys || echo '$(cat "$pubkey_file")' >> ~/.ssh/authorized_keys"; then
        echo "WARNING: could not add public key on $remote_user@$remote_ip"
        return 1
    fi

    echo "Key installed for $remote_user@$remote_ip"
    return 0
}

pull_service_backup() {
    local service="$1"
    local remote_ip="$2"
    local remote_dir="$BACKUP_ROOT/latest/$service"

    echo
    echo "Pulling $service backup from $remote_ip"

    if ! sudo -u backupuser ssh -i /home/backupuser/.ssh/id_rsa -o StrictHostKeyChecking=no \
        "backupuser@$remote_ip" "[ -d '$remote_dir' ]"; then
        echo "WARNING: $service backup directory missing on $remote_ip"
        echo "Skipping $service backup"
        return 0
    fi

    archive_server_service_latest "$service"
    clear_server_service_latest "$service"

    if ! rsync -rltDz --delete \
        -e "ssh -i /home/backupuser/.ssh/id_rsa -o StrictHostKeyChecking=no" \
        "backupuser@$remote_ip:$remote_dir/" \
        "$BACKUP_ROOT/latest/$service/"; then
        echo "WARNING: rsync failed for $service from $remote_ip"
        echo "Continuing"
        return 0
    fi

    finalize_server_service_permissions "$service"
    echo "$service backup pulled successfully"
    return 0
}

pull_all_backups() {
    pull_service_backup web "$WEB_IP"
    pull_service_backup dns "$DNS_IP"
    pull_service_backup db "$DB_IP"
    pull_service_backup smb "$SMB_IP"

    echo
    echo "All service backups processed"
}

remote_rotate_latest() {
    local service="$1"
    local remote_ip="$2"

    if ! sudo -u backupuser ssh -i /home/backupuser/.ssh/id_rsa -o StrictHostKeyChecking=no "backupuser@$remote_ip" "
        BACKUP_ROOT='$BACKUP_ROOT'
        SERVICE='$service'
        TS=\$(date +\"%Y-%m-%d_%H-%M-%S\")
        mkdir -p \"\$BACKUP_ROOT/latest/\$SERVICE\" \"\$BACKUP_ROOT/archive/\$SERVICE\"
        if [ \"\$(find \"\$BACKUP_ROOT/latest/\$SERVICE\" -mindepth 1 -print -quit 2>/dev/null)\" ]; then
            mkdir -p \"\$BACKUP_ROOT/archive/\$SERVICE/\$TS\"
            shopt -s dotglob nullglob
            mv \"\$BACKUP_ROOT/latest/\$SERVICE\"/* \"\$BACKUP_ROOT/archive/\$SERVICE/\$TS\"/
            shopt -u dotglob nullglob
        fi
    "; then
        echo "WARNING: could not rotate client latest for $service on $remote_ip"
        return 1
    fi

    return 0
}

push_dir_to_client_latest() {
    local source_dir="$1"
    local service="$2"
    local remote_ip="$3"

    if [ ! -d "$source_dir" ] || [ -z "$(find "$source_dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        echo "No data found in $source_dir"
        return 1
    fi

    echo
    echo "Archiving existing client latest for $service on $remote_ip"
    remote_rotate_latest "$service" "$remote_ip" || true

    echo
    echo "Pushing $service into client latest on $remote_ip"

    if ! rsync -rltDz --delete \
        -e "ssh -i /home/backupuser/.ssh/id_rsa -o StrictHostKeyChecking=no" \
        "$source_dir/" \
        "backupuser@$remote_ip:$BACKUP_ROOT/latest/$service/"; then
        echo "WARNING: failed to push $service to $remote_ip"
        return 1
    fi

    echo "Push complete"
    return 0
}

restore_from_server_latest() {
    local service="$1"
    local remote_ip="$2"

    if [ ! -d "$BACKUP_ROOT/latest/$service" ] || [ -z "$(find "$BACKUP_ROOT/latest/$service" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        echo "Server latest for $service does not exist"
        return 1
    fi

    push_dir_to_client_latest "$BACKUP_ROOT/latest/$service" "$service" "$remote_ip"
}

restore_from_server_archive() {
    local service="$1"
    local remote_ip="$2"
    local snapshots
    local selected

    if [ ! -d "$BACKUP_ROOT/archive/$service" ]; then
        echo "No archive directory for $service"
        return 1
    fi

    mapfile -t snapshots < <(find "$BACKUP_ROOT/archive/$service" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)

    if [ "${#snapshots[@]}" -eq 0 ]; then
        echo "No archive snapshots found for $service"
        return 1
    fi

    echo
    echo "Available archive snapshots for $service:"
    select selected in "${snapshots[@]}"; do
        if [ -n "${selected:-}" ]; then
            break
        fi
        echo "Invalid selection"
    done

    push_dir_to_client_latest "$BACKUP_ROOT/archive/$service/$selected" "$service" "$remote_ip"
}

restore_latest_menu() {
    echo
    echo "Select service"
    echo "1) web"
    echo "2) dns"
    echo "3) db"
    echo "4) smb"
    echo "5) all"
    read -r CHOICE

    case "$CHOICE" in
        1) restore_from_server_latest web "$WEB_IP" ;;
        2) restore_from_server_latest dns "$DNS_IP" ;;
        3) restore_from_server_latest db "$DB_IP" ;;
        4) restore_from_server_latest smb "$SMB_IP" ;;
        5)
            read -r -p "This will push ALL latest backups to all clients. Continue? (y/n): " CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                restore_from_server_latest web "$WEB_IP"
                restore_from_server_latest dns "$DNS_IP"
                restore_from_server_latest db "$DB_IP"
                restore_from_server_latest smb "$SMB_IP"
            else
                echo "Cancelled"
            fi
            ;;
        *) echo "Invalid selection" ;;
    esac
}

restore_archive_menu() {
    echo
    echo "Select service"
    echo "1) web"
    echo "2) dns"
    echo "3) db"
    echo "4) smb"
    echo "5) all"
    read -r CHOICE

    case "$CHOICE" in
        1) restore_from_server_archive web "$WEB_IP" ;;
        2) restore_from_server_archive dns "$DNS_IP" ;;
        3) restore_from_server_archive db "$DB_IP" ;;
        4) restore_from_server_archive smb "$SMB_IP" ;;
        5)
            read -r -p "This will push archived backups for ALL services. Continue? (y/n): " CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                restore_from_server_archive web "$WEB_IP"
                restore_from_server_archive dns "$DNS_IP"
                restore_from_server_archive db "$DB_IP"
                restore_from_server_archive smb "$SMB_IP"
            else
                echo "Cancelled"
            fi
            ;;
        *) echo "Invalid selection" ;;
    esac
}

configure_team() {
    if [ -f "$TEAM_FILE" ]; then
        TEAM=$(cat "$TEAM_FILE")
        echo
        echo "Using saved team number: $TEAM"
    else
        echo
        read -r -p "Enter team number (1-5): " TEAM
        echo "$TEAM" > "$TEAM_FILE"
    fi

    WEB_IP="192.168.$TEAM.5"
    DB_IP="192.168.$TEAM.7"
    DNS_IP="192.168.$TEAM.12"
    SMB_IP="172.18.14.$TEAM"
    BACKUP_IP="192.168.$TEAM.15"
}

manager_menu() {
    while true; do
        echo
        echo "Select action"
        echo "1) Bootstrap SSH keys to all clients"
        echo "2) Pull backups from all clients"
        echo "3) Restore service from server latest"
        echo "4) Restore service from server archive"
        echo "5) Exit"
        read -r ACTION

        case "$ACTION" in
            1)
                echo
                read -r -s -p "Enter backupuser password used on the client machines: " CLIENT_PASS
                echo

                bootstrap_remote_key backupuser backupuser "$WEB_IP" "$CLIENT_PASS" || true
                bootstrap_remote_key backupuser backupuser "$DNS_IP" "$CLIENT_PASS" || true
                bootstrap_remote_key backupuser backupuser "$DB_IP" "$CLIENT_PASS" || true
                bootstrap_remote_key backupuser backupuser "$SMB_IP" "$CLIENT_PASS" || true

                echo
                echo "SSH bootstrap processed"
                echo "For a secondary backup server, run backup_client.sh on the secondary machine."
                ;;
            2)
                pull_all_backups
                ;;
            3)
                restore_latest_menu
                ;;
            4)
                restore_archive_menu
                ;;
            5)
                exit 0
                ;;
            *)
                echo "Invalid selection"
                ;;
        esac
    done
}

main() {
    require_root
    configure_team
    install_packages

    echo
    echo "Checking backup users..."
    ensure_user backupuser
    ensure_keypair backupuser
    ensure_backup_dirs
    manager_menu
}

main
#!/bin/bash

# Global variables
declare -A shares
declare -A share_options
LOG_FILE="/var/log/nfs_smb_config_script.log"
ADVANCED_OPTIONS=0 # Toggle for advanced options

# Color codes for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging function with timestamps
log_message() {
    local message="$1"
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") - $message" | tee -a "$LOG_FILE"
}

# Progress bar for executing commands
show_progress() {
    local cmd="$1"
    {
        eval "$cmd"
        echo "100"
    } | dialog --gauge "$2" 10 60 0
}

# Ensure dialog is installed
ensure_dialog_installed() {
    if ! command -v dialog &> /dev/null; then
        if [[ -f /etc/os-release ]]; then
            source /etc/os-release
            case "$ID" in
                ubuntu|debian) sudo apt update && sudo apt install -y dialog ;;
                centos|fedora|rhel) sudo dnf install -y dialog ;;
                *) 
                    echo "Unsupported distribution. Please install 'dialog' manually."
                    exit 1 
                    ;;
            esac
        else
            echo "Could not determine OS. Please install 'dialog' manually."
            exit 1
        fi
    fi
}

# Check if the script is run as root
check_root_permissions() {
    if [[ $EUID -ne 0 ]]; then
        dialog --yesno "This script requires root privileges. Do you want to run it with 'sudo'?" 7 60
        if [[ $? -eq 0 ]]; then
            exec sudo bash "$0" "$@"  # Relaunch the script with sudo
        else
            echo "You need root privileges to run this script. Exiting."
            exit 1
        fi
    fi
}

# Determine OS and package manager
determine_os_and_package_manager() {
    if [ -f /etc/redhat-release ]; then
        PM="dnf"
        FW="firewalld"
        NFS_SERVICE="nfs-server"
        SMB_SERVICE="smb"
        NFS_CLIENT_PKG="nfs-utils"
        SMB_CLIENT_PKG="cifs-utils"
    elif [ -f /etc/debian_version ]; then
        PM="apt"
        FW="ufw"
        NFS_SERVICE="nfs-kernel-server"
        SMB_SERVICE="samba"
        NFS_CLIENT_PKG="nfs-common"
        SMB_CLIENT_PKG="cifs-utils"
    else
        log_message "${RED}Unsupported OS.${NC}"
        exit 1
    fi
}

# Sanitize user input (whitelist approach)
sanitize_input() {
    local input="$1"
    # Allow only specific characters
    echo "$input" | sed 's/[^a-zA-Z0-9\.\_\-\/\:\ ]//g'
}

# Get a shared directory using Dialog with file browser
get_shared_directory() {
    dialog --title "Select directory to share" --fselect / 10 60 2> /tmp/dir
    local dir=$(< /tmp/dir)

    # Ensure the directory is writable
    if [[ ! -w "$dir" ]]; then
        dialog --msgbox "Selected directory does not have write permissions. Please select another." 6 60
        return 1
    fi
    echo "$dir"
}

# Get a valid local directory for mounting with permission checks
get_local_directory() {
    while true; do
        local_dir=$(dialog --stdout --title "Select local directory for mounting" --dselect / 10 60)
        if [[ -d "$local_dir" && -w "$local_dir" ]]; then
            break
        else
            dialog --msgbox "Invalid or inaccessible directory. Please select a writable directory." 10 60
        fi
    done
    echo "$local_dir"
}

# Function to get a username for the SMB share
get_smb_username() {
    local username=$(dialog --stdout --title "Enter username for the SMB share" --inputbox "Username:" 8 60)
    echo "$username"
}

# Function to get a password for the SMB share
get_smb_password() {
    local password=$(dialog --stdout --title "Enter password for the SMB share" --passwordbox "Password:" 8 60)
    echo "$password"
}

# Function to get valid network input
get_network() {
    while true; do
        network=$(dialog --inputbox "Enter the network (CIDR notation) or IP address(es) allowed to access the share (e.g., 192.168.1.0/24, 10.0.0.1):" 8 60 2>&1 >/dev/tty)
        if [[ "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]{1,2}))?$ ]] || [[ "$network" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3},)+([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            dialog --msgbox "Invalid network format. Please use CIDR notation or comma-separated IP addresses." 6 60
        fi
    done
    echo "$network"
}

# Function to select file type using Dialog
select_file_type() {
    local filetype=$(dialog --radiolist "Select file type:" 10 40 5 \
        1 "Normal files" on \
        2 "Music" off \
        3 "Documents" off \
        4 "Photos" off \
        5 "Movies/TV" off 2>&1 >/dev/tty)

    case $filetype in
        1) echo "normal files" ;;
        2) echo "music" ;;
        3) echo "documents" ;;
        4) echo "photos" ;;
        5) echo "movies/tv" ;;
    esac
}

# Validate custom NFS mount options
validate_nfs_options() {
    local options="$1"
    if ! echo "$options" | grep -qE '^(rw|ro|sync|async|no_subtree_check|no_root_squash|root_squash|all_squash|anonuid=[0-9]+|anongid=[0-9]+|sec=(sys|krb5|krb5i|krb5p)|rsize=[0-9]+|wsize=[0-9]+)(,[a-zA-Z0-9_\=]+)*$'; then
        return 1
    fi
    return 0
}

# Optimize NFS options with advanced features if required
optimize_nfs_options() {
    local filetype="$1"
    local accessmode="$2"
    local options="rw,sync,no_subtree_check"
    options+=","

    options+=$(case "$filetype" in
        "normal files") echo "rsize=8192,wsize=8192" ;;
        "music"|"documents"|"photos") echo "rsize=4096,wsize=4096" ;;
        "movies/tv") echo "rsize=16384,wsize=16384" ;;
    esac)

    [ "$accessmode" == "read-only" ] && options+=",ro"

    if [[ $ADVANCED_OPTIONS -eq 1 ]]; then
        # Get advanced NFS options if advanced mode is enabled
        advanced_options=$(get_advanced_nfs_options)
        options+=",${advanced_options}"
    fi

    dialog --yesno "Do you want to add custom NFS mount options?" 6 40
    if [ $? -eq 0 ]; then
        custom_options=$(dialog --inputbox "Enter custom NFS mount options (comma-separated):" 8 60 2>&1 >/dev/tty)
        if validate_nfs_options "$custom_options"; then
            options+=",${custom_options}"
        else
            dialog --msgbox "Invalid custom options. Default options will be used." 6 40
        fi
    fi

    echo "$options"
}

# Get advanced NFS options
get_advanced_nfs_options() {
    local advanced_options=""
    local choices=(
        "no_root_squash" "Disable root squashing (insecure)" off
        "root_squash" "Map root UID/GID to anonymous UID/GID" off
        "all_squash" "Map all UID/GID to anonymous UID/GID" off
        "anonuid=65534" "Set anonymous UID" off
        "anongid=65534" "Set anonymous GID" off
        "sec=sys" "Use AUTH_SYS security flavor" on
        "sec=krb5" "Use Kerberos V5 authentication" off
    )

    selected_options=$(dialog --checklist "Select advanced NFS options:" 20 60 10 "${choices[@]}" 2>&1 >/dev/tty)
    for option in $selected_options; do
        advanced_options+="$option,"
    done

    echo "${advanced_options%,}" # Remove trailing comma
}

# Set up NFS exports
setup_nfs_exports() {
    while true; do
        dialog --title "NFS Share Configuration" --msgbox "You will now configure NFS shares." 6 50

        local dir=$(get_shared_directory)
        local network=$(get_network)
        local filetype=$(select_file_type)
        local accessmode=$(dialog --menu "Select access mode:" 10 40 2 1 "Read-only" 2 "Read-write" 2>&1 >/dev/tty)

        local options=$(optimize_nfs_options "$filetype" "$accessmode")

        shares["$dir"]="$network"
        share_options["$dir"]="$options"

        dialog --title "NFS Share" --yesno "Do you want to add another NFS share?" 6 25
        [ $? -ne 0 ] && break
    done

    log_message "Setting up NFS shares..."
    for dir in "${!shares[@]}"; do
        echo "$dir ${shares[$dir]}(${share_options[$dir]})" >> /etc/exports
    done

    log_message "Restarting NFS server..."
    show_progress "sudo systemctl restart $NFS_SERVICE" "Restarting NFS server..."
    sudo exportfs -a
}

# Validate custom SMB options
validate_smb_options() {
    local options="$1"
    if ! echo "$options" | grep -qE '^(read only|writeable|browsable|guest ok|valid users|force user|force group|create mask=[0-7]+|directory mask=[0-7]+|admin users|read list|write list)(=[a-zA-Z0-9,_-]+)?(,(read only|writeable|browsable|guest ok|valid users|force user|force group|create mask=[0-7]+|directory mask=[0-7]+|admin users|read list|write list)(=[a-zA-Z0-9,_-]+)?)*$'; then
        return 1
    fi
    return 0
}

# Optimize SMB options with advanced features if required
optimize_smb_options() {
    local accessmode="$1"
    local username="$2"
    local options="writeable = yes\nbrowsable = yes\nvalid users = $username"

    [ "$accessmode" == "read-only" ] && options="read only = yes\nbrowsable = yes\nvalid users = $username"

    if [[ $ADVANCED_OPTIONS -eq 1 ]]; then
        # Get advanced SMB options if advanced mode is enabled
        advanced_options=$(get_advanced_smb_options)
        options+="\n${advanced_options}"
    fi

    dialog --yesno "Do you want to add custom SMB options?" 6 40
    if [ $? -eq 0 ]; then
        custom_options=$(dialog --inputbox "Enter custom SMB options (comma-separated):" 8 60 2>&1 >/dev/tty)
        if validate_smb_options "$custom_options"; then
            options+="\n${custom_options}"
        else
            dialog --msgbox "Invalid custom options. Default options will be used." 6 40
        fi
    fi

    echo -e "$options"
}

# Get advanced SMB options
get_advanced_smb_options() {
    local advanced_options=""
    local choices=(
        "guest ok = yes" "Allow guest access" off
        "create mask = 0775" "Set file creation mask" off
        "directory mask = 0775" "Set directory creation mask" off
        "force user = nobody" "Force user for file operations" off
        "force group = nogroup" "Force group for file operations" off
        "admin users = root" "Admin users" off
        "read list = @users" "Read-only users/groups" off
        "write list = @users" "Write access users/groups" off
    )

    selected_options=$(dialog --checklist "Select advanced SMB options:" 20 60 10 "${choices[@]}" 2>&1 >/dev/tty)
    for option in $selected_options; do
        advanced_options+="$option\n"
    done

    echo -e "$advanced_options"
}

# Set up SMB shares
setup_smb_shares() {
    while true; do
        dialog --title "SMB Share Configuration" --msgbox "You will now configure SMB shares." 6 50

        local dir=$(get_shared_directory)
        local username=$(get_smb_username)
        local password=$(get_smb_password)
        local accessmode=$(dialog --menu "Select access mode:" 10 40 2 1 "Read-only" 2 "Read-write" 2>&1 >/dev/tty)

        local options=$(optimize_smb_options "$accessmode" "$username")

        shares["$dir"]="$username"
        share_options["$dir"]="$options"

        # Add SMB user and set password
        sudo smbpasswd -a "$username" <<< "$password"$'\n'"$password"

        dialog --title "SMB Share" --yesno "Do you want to add another SMB share?" 6 25
        [ $? -ne 0 ] && break
    done

    log_message "Setting up SMB shares..."
    for dir in "${!shares[@]}"; do
        echo -e "[$(basename $dir)]\npath = $dir\n${share_options[$dir]}" >> /etc/samba/smb.conf
    done

    log_message "Restarting SMB server..."
    show_progress "sudo systemctl restart $SMB_SERVICE" "Restarting SMB server..."
}

# Configure NFS Client
configure_nfs_client() {
    log_message "Installing NFS client packages..."
    show_progress "sudo $PM install -y $NFS_CLIENT_PKG" "Installing NFS client packages..."

    local server_ip=$(dialog --inputbox "Enter the NFS server IP address:" 8 40 2>&1 >/dev/tty)
    local server_dir=$(dialog --inputbox "Enter the directory on the NFS server to mount:" 8 60 2>&1 >/dev/tty)
    local local_dir=$(get_local_directory)

    log_message "Mounting NFS share..."
    sudo mount -t nfs "$server_ip:$server_dir" "$local_dir"

    dialog --yesno "Do you want to add this mount to /etc/fstab for persistence?" 6 40
    if [ $? -eq 0 ]; then
        echo "$server_ip:$server_dir $local_dir nfs defaults 0 0" | sudo tee -a /etc/fstab
    fi

    dialog --msgbox "NFS client configuration completed." 6 40
}

# Configure SMB Client
configure_smb_client() {
    log_message "Installing SMB client packages..."
    show_progress "sudo $PM install -y $SMB_CLIENT_PKG" "Installing SMB client packages..."

    local server_ip=$(dialog --inputbox "Enter the SMB server IP address:" 8 40 2>&1 >/dev/tty)
    local share_name=$(dialog --inputbox "Enter the name of the SMB share:" 8 60 2>&1 >/dev/tty)
    local local_dir=$(get_local_directory)
    local username=$(get_smb_username)
    local password=$(get_smb_password)

    log_message "Mounting SMB share..."
    sudo mount -t cifs "//$server_ip/$share_name" "$local_dir" -o username="$username",password="$password"

    dialog --yesno "Do you want to add this mount to /etc/fstab for persistence?" 6 40
    if [ $? -eq 0 ]; then
        echo "//$server_ip/$share_name $local_dir cifs username=$username,password=$password 0 0" | sudo tee -a /etc/fstab
    fi

    dialog --msgbox "SMB client configuration completed." 6 40
}

# Main function to start the script
main() {
    ensure_dialog_installed
    check_root_permissions
    determine_os_and_package_manager

    dialog --title "NFS and SMB Configuration Script" --msgbox "Welcome to the NFS and SMB configuration script." 6 60

    while true; do
        CHOICE=$(dialog --clear --backtitle "Main Menu" \
            --title "Select Service" \
            --menu "Choose a service to configure:" 15 40 6 \
            "1" "Configure NFS Server" \
            "2" "Configure SMB Server" \
            "3" "Configure NFS Client" \
            "4" "Configure SMB Client" \
            "5" "Exit" \
            2>&1 >/dev/tty)

        case $CHOICE in
            1) setup_nfs_exports ;;
            2) setup_smb_shares ;;
            3) configure_nfs_client ;;
            4) configure_smb_client ;;
            5) break ;;
        esac
    done
}

main "$@"

#!/bin/bash

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

# Global variables
declare -A shares
declare -A share_options
LOG_FILE="/var/log/nfs_smb_config_script.log"
ADVANCED_OPTIONS=0 # Toggle for advanced options

# Color codes for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Determine OS and package manager
determine_os_and_package_manager() {
    if [ -f /etc/redhat-release ]; then
        PM="dnf"
        FW="firewalld"
        NFS_SERVICE="nfs-server"
        SMB_SERVICE="samba"
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
    echo "$input" | sed 's/[^a-zA-Z0-9._\-\/: ]//g'
}

# Get a shared directory using Dialog with file browser
get_shared_directory() {
    dialog --title "Select directory to share" --fselect / 10 60 2> /tmp/dir
    local dir=$(< /tmp/dir)

    if [[ ! -d "$dir" || ! -w "$dir" ]]; then
        dialog --msgbox "The selected directory must exist and be writable. Please select another." 6 60
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
        if [[ "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ "$network" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3},)+([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
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
    if ! echo "$options" | grep -qE '^(rw|ro|sync|async|no_subtree_check|no_root_squash|root_squash|all_squash|anonuid=[0-9]+|anongid=[0-9]+|sec=(sys|krb5|krb5i|krb5p)|rsize=[0-9]+|wsize=[0-9]+)(,[a-zA-Z0-9_=]+)*$'; then
       return 1
    fi
    return 0
}

# Optimize NFS options with advanced features if required
optimize_nfs_options() {
    local filetype="$1"
    local accessmode="$2"
    local options="rw,sync,no_subtree_check"

    options+=",$(case "$filetype" in
        "normal files") echo "rsize=8192,wsize=8192" ;;
        "music"|"documents"|"photos") echo "rsize=4096,wsize=4096" ;;
        "movies/tv") echo "rsize=16384,wsize=16384" ;;
    esac)"

    [ "$accessmode" == "read-only" ] && options+=",ro"

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

# Set up NFS exports
setup_nfs_exports() {
    while true; do
        directory=$(get_shared_directory)
        if [[ $? -eq 1 ]]; then continue; fi 

        network=$(get_network)
        accessmode=$(dialog --radiolist "Select access mode:" 10 40 2 \
            1 "read-only" on \
            2 "read/write" off 2>&1 >/dev/tty)

        [ "$accessmode" -eq 1 ] && accessmode="read-only" || accessmode="read/write"

        options="$(optimize_nfs_options "$(select_file_type)" "$accessmode")"
        shares["$directory"]="$network($options,fsid=$(uuidgen))"

        echo "$directory $network($options)" | sudo tee -a /etc/exports > /dev/null

        if ! sudo exportfs -ra; then
            dialog --msgbox "Error reloading NFS exports." 6 40
            exit 1
        fi

        if ! sudo systemctl enable --now $NFS_SERVICE; then
            dialog --msgbox "Error enabling/starting NFS service." 6 40
            exit 1
        fi

        log_message "${GREEN}NFS export setup complete.${NC}"
        break
    done
}

# Set up SMB exports
setup_smb_exports() {
    while true; do
        directory=$(get_shared_directory)
        if [[ $? -eq 1 ]]; then continue; fi 

        sharename=$(dialog --stdout --title "Enter share name for the SMB share" --inputbox "Share Name:" 8 60)
        sharename=$(sanitize_input "$sharename")
        
        accessmode=$(dialog --radiolist "Select access mode:" 10 40 2 \
            1 "read-only" on \
            2 "read/write" off 2>&1 >/dev/tty)

        [ "$accessmode" -eq 1 ] && accessmode="read-only" || accessmode="read/write"

        options="path = $directory\nbrowseable = yes\n"
        options+=[ "$accessmode" == "read-only" ] && "read only = yes\n" || "read only = no\n"

        dialog --yesno "Do you want to add custom SMB share options?" 6 40
        if [ $? -eq 0 ]; then
            while true; do
                custom_option=$(dialog --inputbox "Enter custom SMB share options (one per line, blank line to finish):" 8 60 2>&1 >/dev/tty)
                [ -z "$custom_option" ] && break
                options+="$custom_option\n"
            done 
        fi

        share_options["$directory"]="$options"
        shares["$sharename"]="$directory"

        echo "[$sharename]\n$options" | sudo tee -a /etc/samba/smb.conf 

        if ! sudo systemctl enable --now $SMB_SERVICE; then
            dialog --msgbox "Error enabling/starting SMB service." 6 40
            exit 1
        fi

        log_message "${GREEN}SMB share setup complete.${NC}"
        break
    done
}

# Function for managing NFS shares
manage_nfs_shares() {
    while true; do
        nfs_shares_list=$(exportfs -v | awk '{print $1, $3}' | column -t)
        
        if [[ -z "$nfs_shares_list" ]]; then
            dialog --msgbox "No NFS shares found." 6 30
            break
        fi

        selected_share=$(dialog --menu "Select an NFS share to manage:" 20 60 10 $nfs_shares_list 3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]]; then break; fi  # Exit if user cancels

        manage_nfs_share "$selected_share"
    done
}

# Function to manage an individual NFS share
manage_nfs_share() {
    local directory="$1"

    while true; do
        action=$(dialog --menu "Choose an action for NFS share '$directory':" 15 50 3 \
            1 "Edit" \
            2 "Delete" \
            3 "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $action in
            1) 
                dialog --msgbox "Editing functionality for NFS shares will be implemented next." 6 40
                # Here you would implement the logic to show and edit current settings
                ;;
            2) 
                sudo sed -i "/^$directory /d" /etc/exports
                sudo exportfs -ra
                dialog --msgbox "NFS share '$directory' deleted." 6 30
                log_message "Deleted NFS share: $directory"
                break
                ;;
            3) 
                break
                ;;
        esac
    done
}

# Function for managing SMB shares
manage_smb_shares() {
    while true; do
        smb_shares_list=$(testparm -s | grep -E '^\[' | cut -d ']' -f 1 | cut -d '[' -f 2)
        
        if [[ -z "$smb_shares_list" ]]; then
            dialog --msgbox "No SMB shares found." 6 30
            break
        fi

        selected_share=$(dialog --menu "Select an SMB share to manage:" 20 60 10 $smb_shares_list 3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]]; then break; fi  # Exit if user cancels

        manage_smb_share "$selected_share"
    done
}

# Function to manage an individual SMB share
manage_smb_share() {
    local sharename="$1"

    while true; do
        action=$(dialog --menu "Choose an action for SMB share '$sharename':" 15 50 3 \
            1 "Edit" \
            2 "Delete" \
            3 "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $action in
            1) 
                dialog --msgbox "Editing functionality for SMB shares will be implemented next." 6 40
                # Here you would implement the logic to show and edit current settings
                ;;
            2) 
                sudo sed -i "/^\[$sharename\]/,/^\[/d" /etc/samba/smb.conf
                sudo systemctl restart smbd
                dialog --msgbox "SMB share '$sharename' deleted." 6 30
                log_message "Deleted SMB share: $sharename"
                break
                ;;
            3) 
                break
                ;;
        esac
    done
}

# Firewall configuration function
configure_firewall() {
    log_message "Configuring firewall..."
    if [ "$FW" == "firewalld" ]; then
        sudo firewall-cmd --permanent --add-service=nfs
        sudo firewall-cmd --permanent --add-service=mountd
        sudo firewall-cmd --permanent --add-service=rpc-bind
        sudo firewall-cmd --permanent --add-service=samba
        sudo firewall-cmd --reload
        log_message "${GREEN}Firewall configured successfully.${NC}"
    elif [ "$FW" == "ufw" ]; then
        sudo ufw allow proto tcp from any to any port 2049
        sudo ufw allow proto udp from any to any port 2049
        sudo ufw allow proto tcp from any to any port 111
        sudo ufw allow proto udp from any to any port 111
        sudo ufw allow proto udp from any to any port 137
        sudo ufw allow proto udp from any to any port 138
        sudo ufw allow proto tcp from any to any port 139
        sudo ufw allow proto tcp from any to any port 445
        log_message "${GREEN}Firewall configured successfully.${NC}"
        sudo ufw reload
    fi
}

# Display main menu
display_main_menu() {
    while true; do
        cmd=(dialog --clear --backtitle "NFS/SMB Configuration Script" --title "Main Menu" --menu "Choose an option:" 0 0 0)
        options=(
            1 "Install NFS Client"
            2 "Install NFS Server"
            3 "Install SMB Client"
            4 "Install SMB Server"
            5 "Manage NFS Shares"
            6 "Manage SMB Shares"
            7 "Toggle Advanced Options"
            8 "Exit"
        )
        choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)

        case $choice in
            1) install_nfs_client && setup_nfs_exports ;;
            2) install_nfs_server && setup_nfs_exports ;;
            3) install_smb_client && setup_smb_exports ;;
            4) install_smb_server && setup_smb_exports ;;
            5) manage_nfs_shares ;;
            6) manage_smb_shares ;;
            7) 
                ADVANCED_OPTIONS=$((1-ADVANCED_OPTIONS))  # Toggle advanced options 
                if [ $ADVANCED_OPTIONS -eq 1 ]; then
                    dialog --msgbox "Advanced Options are now enabled." 6 40
                else
                    dialog --msgbox "Advanced Options are now disabled." 6 40
                fi
                ;;
            8) 
                dialog --yesno "Are you sure you want to exit?" 6 30
                if [[ $?

#!/bin/bash

# Ensure dialog is installed
if ! command -v dialog &> /dev/null; then
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian) show_progress "sudo apt update && sudo apt install -y dialog" "Installing dialog..." ;;
            centos|fedora|rhel) show_progress "sudo dnf install -y dialog" "Installing dialog..." ;;
            *) echo "Unsupported distribution. Please install 'dialog' manually." && exit 1 ;;
        esac
    else
        echo "Could not determine OS. Please install 'dialog' manually."
        exit 1
    fi
fi

# Global variables
declare -A shares
declare -A share_options
LOG_FILE="/var/log/nfs_smb_config_script.log"

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

# Logging function with timestamps
log_message() {
    local message="$1"
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") - $message" | tee -a "$LOG_FILE"
}

# Progress bar
show_progress() {
    local cmd="$1"
    {
        $cmd
        echo "100"
    } | dialog --gauge "$2" 10 60 0
}

# Install NFS server
install_nfs_server() {
    log_message "Installing NFS server utilities using $PM..."
    show_progress "sudo $PM update -y && sudo $PM install -y $NFS_SERVICE" "Installing NFS server utilities..."
    if ! command -v exportfs &> /dev/null; then
        log_message "${RED}NFS server utilities installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}NFS server utilities installed successfully.${NC}"
}

# Install NFS client
install_nfs_client() {
    log_message "Installing NFS client utilities using $PM..."
    show_progress "sudo $PM update -y && sudo $PM install -y $NFS_CLIENT_PKG" "Installing NFS client utilities..."
    if ! command -v mount.nfs &> /dev/null; then
        log_message "${RED}NFS client installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}NFS client utilities installed successfully.${NC}"
}

# Install SMB server
install_smb_server() {
    log_message "Installing SMB server utilities using $PM..."
    show_progress "sudo $PM update -y && sudo $PM install -y $SMB_SERVICE" "Installing SMB server utilities..."
    if ! command -v smbd &> /dev/null; then
        log_message "${RED}SMB server utilities installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}SMB server utilities installed successfully.${NC}"
}

# Install SMB client
install_smb_client() {
    log_message "Installing SMB client utilities using $PM..."
    show_progress "sudo $PM update -y && sudo $PM install -y $SMB_CLIENT_PKG" "Installing SMB client utilities..."
    if ! command -v mount.cifs &> /dev/null; then
        log_message "${RED}SMB client installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}SMB client utilities installed successfully.${NC}"
}

# Function to get a shared directory using Dialog with file browser
get_shared_directory() {
    local dir=$(dialog --stdout --title "Select directory to share" --fselect / 10 60)
    echo "$dir"
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

# Function to get a valid network input
get_network() {
    while true; do
        network=$(dialog --inputbox "Enter the network (CIDR notation) or IP address(es) allowed to access the share (e.g., 192.168.1.0/24, 10.0.0.1):" 8 60 2>&1 >/dev/tty)
        network=$(sanitize_input "$network")
        if [[ "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ "$network" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3},)+([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            dialog --msgbox "Invalid network format. Please use CIDR notation (e.g., 192.168.1.0/24) or comma-separated IP addresses (e.g., 192.168.1.100,192.168.1.101)." 6 60
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

# Enhance the optimize_nfs_options function for security and greater user flexibility
optimize_nfs_options() {
    local filetype="$1"
    local accessmode="$2"
    local options="rw,sync,no_subtree_check,secure"

    case "$filetype" in
        "normal files") options+=",rsize=8192,wsize=8192" ;;
        "music"|"documents"|"photos") options+=",rsize=4096,wsize=4096" ;;
        "movies/tv") options+=",rsize=16384,wsize=16384" ;;
    esac

    [ "$accessmode" == "read-only" ] && options+=",ro"

    while true; do
        custom_opts=$(dialog --yesno "Do you want to add custom NFS mount options?" 6 40)
        if [ $? -eq 0 ]; then
            custom_options=$(dialog --inputbox "Enter custom NFS mount options (comma-separated):" 8 60 2>&1 >/dev/tty)
            if validate_nfs_options "$custom_options"; then
                options+=",${custom_options}"
                break
            else
                dialog --msgbox "Invalid options format or unsupported options. Please try again." 6 60
            fi
        else
            break
        fi
    done

    echo "$options"
}

# Validate custom NFS mount options
validate_nfs_options() {
    local options="$1"
    if ! echo "$options" | grep -qE '^(rw|ro|sync|async|no_subtree_check|no_root_squash|root_squash|all_squash|anonuid=[0-9]+|anongid=[0-9]+|sec=(sys|krb5|krb5i|krb5p)|rsize=[0-9]+|wsize=[0-9]+)(,[a-zA-Z0-9_=]+)*$'; then
       return 1
    fi
    if echo "$options" | grep -qE '(^|,)no_root_squash(,|$)'; then
        echo "WARNING: 'no_root_squash' is insecure and generally not recommended."
    fi
    return 0
}

# Sanitize user input
sanitize_input() {
    local input="$1"
    echo "$input" | sed 's/[^a-zA-Z0-9 ._\/-:]//g'
}

# Set up NFS exports
setup_nfs_exports() {
    while true; do
        directory=$(get_shared_directory)
        if [[ -d "$directory" && -w "$directory" ]]; then  # Check for both existence and write permission
            break
        else
            dialog --msgbox "Invalid or inaccessible directory. Please select a directory where you have write permissions." 10 60
        fi
    done

    network=$(get_network)
    filetype=$(select_file_type)
    accessmode=$(dialog --radiolist "Select access mode:" 10 40 2 \
        1 "read-only" on \
        2 "read/write" off 2>&1 >/dev/tty)

    [ "$accessmode" -eq 1 ] && accessmode="read-only" || accessmode="read/write"

    options=$(optimize_nfs_options "$filetype" "$accessmode")
    share_options["$directory"]="$options"
    fsid=$(uuidgen)
    shares["$directory"]="$network($options,fsid=$fsid)"

    # Use tee with sudo for /etc/exports modification
    echo "$directory $network($options,fsid=$fsid)" | sudo tee -a /etc/exports > /dev/null

    if ! sudo exportfs -ra; then
        log_message "${RED}Error reloading NFS exports.${NC}"
        exit 1
    fi

    if ! sudo systemctl enable --now $NFS_SERVICE; then
        log_message "${RED}Error enabling/starting NFS service.${NC}"
        exit 1
    fi

    configure_firewall # Assuming you have a firewall configuration function
    log_message "${GREEN}NFS export setup complete.${NC}"
}

# Function to get a valid local directory for mounting with permission checks
get_local_directory() {
    while true; do
        local_dir=$(dialog --stdout --title "Select local directory for mounting" --dselect / 10 60)
        if [[ -d "$local_dir" && -w "$local_dir" ]]; then
            break
        else
            dialog --msgbox "Invalid or inaccessible directory. Please select a directory where you have write permissions." 10 60
        fi
    done
    echo "$local_dir"
}

# Set up NFS client
setup_nfs_client() {
    server=$(dialog --stdout --title "Enter NFS server address" --inputbox "Enter the NFS server hostname or IP address:" 8 60)
    server=$(sanitize_input "$server")
    
    remote_dir=$(dialog --stdout --title "Enter remote directory" --inputbox "Enter the remote directory to mount:" 8 60)
    remote_dir=$(sanitize_input "$remote_dir")
    
    local_dir=$(get_local_directory)

    filetype=$(select_file_type)

    if ! ping -c 3 "$server" &> /dev/null; then
        log_message "${RED}Cannot reach NFS server $server.${NC}"
        return 1  # Return an error code instead of exiting immediately
    fi

    if ! showmount -e "$server" | grep -q "$remote_dir"; then
        log_message "${RED}Remote directory $remote_dir is not being shared by the NFS server. Ensure NFS server is running and network is accessible.${NC}"
        return 1
    fi

    options=$(optimize_nfs_options "$filetype" "read/write")
    while true; do
        sudo mount -t nfs "$server:$remote_dir" "$local_dir" -o "$options"
        if mount | grep "$local_dir" > /dev/null; then
            log_message "${GREEN}NFS share mounted successfully.${NC}"
            echo "$server:$remote_dir $local_dir nfs $options 0 0" | sudo tee -a /etc/fstab 
            break
        else
            log_message "${RED}Failed to mount NFS share. Ensure NFS server is running and network is accessible.${NC}"
            read -p "Retry mounting? (yes/no): " retry
            case $retry in
                [Yy]*) continue ;;
                [Nn]*) return 1 ;;
                *) echo "Invalid choice. Exiting."; return 1 ;;
            esac
        fi
    done
}

setup_smb_exports() {
    while true; do
        directory=$(get_shared_directory)
        if [[ -d "$directory" && -w "$directory" ]]; then  # Check for both existence and write permission
            break
        else
            dialog --msgbox "Invalid or inaccessible directory. Please select a directory where you have write permissions." 10 60
        fi
    done

    sharename=$(dialog --stdout --title "Enter share name for the SMB share" --inputbox "Share Name:" 8 60) 
    sharename=$(sanitize_input "$sharename")
    
    accessmode=$(dialog --radiolist "Select access mode:" 10 40 2 \
        1 "read-only" on \
        2 "read/write" off 2>&1 >/dev/tty)

    [ "$accessmode" -eq 1 ] && accessmode="read-only" || accessmode="read/write"

    options="path = $directory\nbrowseable = yes\n"
    options+=[ "$accessmode" == "read-only" ] && "read only = yes\n" || "read only = no\n"

    custom_opts=$(dialog --yesno "Do you want to add custom SMB share options?" 6 40)
    if [ $? -eq 0 ]; then
        while true; do
            custom_option=$(dialog --inputbox "Enter custom SMB share options (one per line, blank line to finish):" 8 60 2>&1 >/dev/tty)
            [ -z "$custom_option" ] && break
            options+="$custom_option\n"
        done 
    fi

    share_options["$directory"]="$options"
    shares["$sharename"]="$directory"

    show_progress "sudo bash -c 'cat >> /etc/samba/smb.conf <<EOL
[$sharename]
$options
EOL'" "Setting up SMB export..."

    if ! sudo systemctl enable --now $SMB_SERVICE; then
        log_message "${RED}Error enabling/starting SMB service.${NC}"
        exit 1
    fi

    configure_firewall # Assuming you have a firewall configuration function
    log_message "${GREEN}SMB share setup complete.${NC}"
}

# Add functions for better management of NFS/SMB shares here...
manage_nfs_shares() {
    dialog --msgbox "NFS Share Management is not implemented yet. Stay tuned!" 6 40
}

manage_smb_shares() {
    dialog --msgbox "SMB Share Management is not implemented yet. Stay tuned!" 6 40
}

configure_firewall() {
    log_message "Configuring firewall..."
    if [ "$FW" == "firewalld" ]; then
        sudo firewall-cmd --permanent --add-service=nfs
        sudo firewall-cmd --permanent --add-service=mountd
        sudo firewall-cmd --permanent --add-service=rpc-bind
        sudo firewall-cmd --permanent --add-service=samba
        sudo firewall-cmd --reload
        if [ $? -ne 0 ]; then
            log_message "${RED}Failed to configure firewalld.${NC}"
            exit 1
        fi
    elif [ "$FW" == "ufw" ]; then
        sudo ufw allow proto tcp from any to any port 2049
        sudo ufw allow proto udp from any to any port 2049
        sudo ufw allow proto tcp from any to any port 111
        sudo ufw allow proto udp from any to any port 111
        sudo ufw allow proto udp from any to any port 137
        sudo ufw allow proto udp from any to any port 138
        sudo ufw allow proto tcp from any to any port 139
        sudo ufw allow proto tcp from any to any port 445
        sudo ufw reload
        if [ $? -ne 0 ]; then
            log_message "${RED}Failed to configure UFW.${NC}"
            exit 1
        fi
    fi
    log_message "${GREEN}Firewall configured successfully.${NC}"
}

display_main_menu() {
    local show_advanced=0 # Toggle for advanced options
    while true; do
        if [ $show_advanced -eq 1 ]; then
            cmd=(dialog --clear --backtitle "NFS/SMB Configuration Script" --title "Main Menu" --menu "Choose an option:" 0 0 0)
            options=(
                1 "Install NFS Client"
                2 "Install NFS Server"
                3 "Install SMB Client"
                4 "Install SMB Server"
                5 "Manage NFS Shares"
                6 "Manage SMB Shares"
                7 "Exit"
                8 "Toggle Advanced Options (off)"
            )
        else
            cmd=(dialog --clear --backtitle "NFS/SMB Configuration Script" --title "Main Menu" --menu "Choose an option:" 0 0 0)
            options=(
                1 "Install NFS Client"
                2 "Install NFS Server"
                3 "Install SMB Client"
                4 "Install SMB Server"
                5 "Manage NFS Shares"
                6 "Manage SMB Shares"
                7 "Exit"
                8 "Toggle Advanced Options (on)"
            )

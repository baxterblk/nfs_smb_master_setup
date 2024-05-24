#!/bin/bash

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

# Logging function
log_message() {
    local message="$1"
    echo -e "$message" | tee -a "$LOG_FILE"
}

# Install NFS server
install_nfs_server() {
    log_message "Installing NFS server utilities using $PM..."
    sudo $PM update -y
    sudo $PM install -y $NFS_SERVICE
    if ! command -v exportfs &> /dev/null; then
        log_message "${RED}NFS server utilities installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}NFS server utilities installed successfully.${NC}"
}

# Install NFS client
install_nfs_client() {
    log_message "Installing NFS client utilities using $PM..."
    sudo $PM update -y
    sudo $PM install -y $NFS_CLIENT_PKG
    if ! command -v mount.nfs &> /dev/null; then
        log_message "${RED}NFS client installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}NFS client utilities installed successfully.${NC}"
}

# Install SMB server
install_smb_server() {
    log_message "Installing SMB server utilities using $PM..."
    sudo $PM update -y
    sudo $PM install -y $SMB_SERVICE
    if ! command -v smbd &> /dev/null; then
        log_message "${RED}SMB server utilities installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}SMB server utilities installed successfully.${NC}"
}

# Install SMB client
install_smb_client() {
    log_message "Installing SMB client utilities using $PM..."
    sudo $PM update -y
    sudo $PM install -y $SMB_CLIENT_PKG
    if ! command -v mount.cifs &> /dev/null; then
        log_message "${RED}SMB client installation failed.${NC}"
        exit 1
    fi
    log_message "${GREEN}SMB client utilities installed successfully.${NC}"
}

# Configure firewall for NFS and SMB
configure_firewall() {
    if [ "$FW" == "firewalld" ]; then
        log_message "Configuring firewalld for NFS and SMB..."
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
        log_message "Configuring UFW for NFS and SMB..."
        sudo ufw allow from any to any port 2049 proto tcp
        sudo ufw allow from any to any port 111 proto tcp
        sudo ufw allow from any to any port 111 proto udp
        sudo ufw allow from any to any port 2049 proto udp
        sudo ufw allow from any to any port 137 proto udp
        sudo ufw allow from any to any port 138 proto udp
        sudo ufw allow from any to any port 139 proto tcp
        sudo ufw allow from any to any port 445 proto tcp
        sudo ufw reload
        if [ $? -ne 0 ]; then
            log_message "${RED}Failed to configure UFW.${NC}"
            exit 1
        fi
    fi
    log_message "${GREEN}Firewall configured successfully.${NC}"
}

# Optimize NFS mount options (with input validation and comment enhancements)
optimize_nfs_options() {
    local filetype="$1"
    local accessmode="$2"
    local options="rw,sync,no_subtree_check"

    case "$filetype" in
        "normal files")
            options+=",rsize=8192,wsize=8192"
            ;;
        "music" | "documents" | "photos")
            options+=",rsize=4096,wsize=4096"
            ;;
        "movies/tv")
            options+=",rsize=16384,wsize=16384"
            ;;
    esac

    [ "$accessmode" == "read-only" ] && options+=",ro"

    while true; do
        read -p "Do you want to add custom NFS mount options? (yes/no): " custom_opts
        case $custom_opts in
            [Yy][Ee][Ss]|[Yy])
                while true; do
                    read -p "Enter custom NFS mount options (comma-separated): " custom_options
                    if validate_nfs_options "$custom_options"; then
                        options+=",${custom_options}"
                        break
                    else
                        echo "Invalid options format or unsupported options. Please try again."
                    fi
                done
                break
                ;;
            [Nn][Oo]|[Nn]) break ;;
            *) echo "Invalid choice. Please enter 'yes' or 'no'." ;;
        esac
    done

    echo "$options"
}

# Validate custom NFS mount options (enhanced for security)
validate_nfs_options() {
    local options="$1"

    # More concise regex for option validation
    if ! echo "$options" | grep -qE '^(rw|ro|sync|async|no_subtree_check|no_root_squash|root_squash|all_squash|anonuid=[0-9]+|anongid=[0-9]+|sec=(sys|krb5|krb5i|krb5p)|rsize=[0-9]+|wsize=[0-9]+)(,[a-zA-Z0-9_=]+)*$'; then
       return 1
    fi

    if echo "$options" | grep -qE '(^|,)no_root_squash(,|$)'; then
        echo "WARNING: 'no_root_squash' is insecure and generally not recommended."
    fi
    return 0
}

# Sanitize user input (improved regex)
sanitize_input() {
    local input="$1"
    echo "$input" | sed 's/[^a-zA-Z0-9 ._\/-:]//g'
}

# Validate network input
validate_network() {
    local network="$1"
    if [[ "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || \
       [[ "$network" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3},)*([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Get and validate the directory to share
get_shared_directory() {
    while true; do
        read -p "Enter the full path of the directory to share: " directory
        directory=$(sanitize_input "$directory")
        [ -d "$directory" ] && break || echo "Invalid directory path. Please try again."
    done
    echo "$directory"
}

# Get and validate the network input
get_network() {
    while true; do
        read -p "Enter the network (CIDR notation) or IP address(es) allowed to access the share: " network
        network=$(sanitize_input "$network")
        if validate_network "$network"; then
            break
        else
            echo "Invalid network format. Please use CIDR notation (e.g., 192.168.1.0/24) or comma-separated IP addresses (e.g., 192.168.1.100,192.168.1.101)."
        fi
    done
    echo "$network"
}

# Set up NFS exports
setup_nfs_exports() {
    directory=$(get_shared_directory)
    network=$(get_network)

    select filetype in "normal files" "music" "documents" "photos" "movies/tv"; do
        if [ -n "$REPLY" ]; then
            filetype=$(sanitize_input "$filetype")
            break
        else
            echo "Invalid choice. Please select a file type."
        fi
    done

    select accessmode in "read-only" "read/write"; do
        if [ -n "$REPLY" ]; then
            accessmode=$(sanitize_input "$accessmode")
            break
        else
            echo "Invalid choice. Please select an access mode."
        fi
    done

    options=$(optimize_nfs_options "$filetype" "$accessmode")
    share_options["$directory"]="$options"
    fsid=$(uuidgen)
    shares["$directory"]="$network($options,fsid=$fsid)"

    echo "$directory $network($options,fsid=$fsid)" | sudo tee -a /etc/exports > /dev/null
    
    if ! sudo exportfs -ra; then
        log_message "${RED}Error reloading NFS exports.${NC}"
        exit 1
    fi

    if ! sudo systemctl enable --now $NFS_SERVICE; then
        log_message "${RED}Error enabling/starting NFS service.${NC}"
        exit 1
    fi
    configure_firewall
    log_message "${GREEN}NFS export setup complete.${NC}"
}

# Set up SMB exports
setup_smb_exports() {
    directory=$(get_shared_directory)
    read -p "Enter the name of the SMB share: " sharename
    sharename=$(sanitize_input "$sharename")

    select accessmode in "read-only" "read/write"; do
        if [ -n "$REPLY" ]; then
            accessmode=$(sanitize_input "$accessmode")
            break
        else
            echo "Invalid choice. Please select an access mode."
        fi
    done

    # Initialize with default options
    options="path = $directory\n"
    options+="browseable = yes\n" # Always make share browseable

    if [ "$accessmode" == "read-only" ]; then
        options+="read only = yes\n"
    else
        options+="read only = no\n"
    fi

    # Allow customization of additional options
    while true; do
        read -p "Do you want to add custom SMB share options? (yes/no): " custom_opts
        case $custom_opts in
            [Yy][Ee][Ss]|[Yy])
                while true; do
                    read -p "Enter custom SMB share options (one per line, blank line to finish): " custom_option
                    if [ -z "$custom_option" ]; then
                        break  # Exit loop on blank line
                    fi
                    options+="$custom_option\n"  # Add option to the string
                done
                break
                ;;
            [Nn][Oo]|[Nn]) break ;;
            *) echo "Invalid choice. Please enter 'yes' or 'no'." ;;
        esac
    done

    share_options["$directory"]="$options"
    shares["$sharename"]="$directory"

    sudo bash -c "cat >> /etc/samba/smb.conf <<EOL
[$sharename]
$options
EOL"

    if ! sudo systemctl enable --now $SMB_SERVICE; then
        log_message "${RED}Error enabling/starting SMB service.${NC}"
        exit 1
    fi
    configure_firewall
    log_message "${GREEN}SMB share setup complete.${NC}"
}

# Set up NFS client (with error checks and retry)
setup_nfs_client() {
    read -p "Enter the NFS server hostname or IP address: " server
    server=$(sanitize_input "$server")
    read -p "Enter the remote directory to mount: " remote_dir
    remote_dir=$(sanitize_input "$remote_dir")
    read -p "Enter the local directory where the remote share will be mounted: " local_dir
    local_dir=$(sanitize_input "$local_dir")

    select filetype in "normal files" "music" "documents" "photos" "movies/tv"; do
        if [ -n "$REPLY" ]; then
            filetype=$(sanitize_input "$filetype")
            break
        else
            echo "Invalid choice. Please select a file type."
        fi
    done

    if ! ping -c 3 "$server" &> /dev/null; then
        log_message "${RED}Cannot reach NFS server $server.${NC}"
        exit 1
    fi

    if ! showmount -e "$server" | grep -q "$remote_dir"; then
        log_message "${RED}Remote directory $remote_dir is not being shared by the NFS server. Ensure NFS server is running and network is accessible.${NC}"
        exit 1
    fi

    [ ! -d "$local_dir" ] && sudo mkdir -p "$local_dir"

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
                [Nn]*) exit 1 ;;
                *) echo "Invalid choice. Exiting."; exit 1 ;;
            esac
        fi
    done
}

# Set up SMB client (with error checks and retry)
setup_smb_client() {
    read -p "Enter the SMB server hostname or IP address: " server
    server=$(sanitize_input "$server")
    read -p "Enter the name of the remote SMB share: " sharename
    sharename=$(sanitize_input "$sharename")
    read -p "Enter the local directory where the remote share will be mounted: " local_dir
    local_dir=$(sanitize_input "$local_dir")

    read -p "Enter the username for accessing the SMB share: " username
    read -sp "Enter the password for accessing the SMB share: " password
    echo

    if ! ping -c 3 "$server" &> /dev/null; then
        log_message "${RED}Cannot reach SMB server $server.${NC}"
        exit 1
    fi

    [ ! -d "$local_dir" ] && sudo mkdir -p "$local_dir"

    options="username=$username,password=$password"
    while true; do
        sudo mount -t cifs "//$server/$sharename" "$local_dir" -o "$options"
        if mount | grep "$local_dir" > /dev/null; then
            log_message "${GREEN}SMB share mounted successfully.${NC}"
            echo "//$server/$sharename $local_dir cifs $options 0 0" | sudo tee -a /etc/fstab 
            break
        else
            log_message "${RED}Failed to mount SMB share. Ensure SMB server is running and network is accessible.${NC}"
            read -p "Retry mounting? (yes/no): " retry
            case $retry in
                [Yy]*) continue ;;
                [Nn]*) exit 1 ;;
                *) echo "Invalid choice. Exiting."; exit 1 ;;
            esac
        fi
    done
}

# Function to remove specific options from an NFS share
remove_nfs_share_options() {
    read -p "Enter the full path of the share to modify: " directory
    directory=$(sanitize_input "$directory")
    if [ -n "${share_options[$directory]}" ]; then
        echo "Current options for $directory: ${share_options[$directory]}"
        read -p "Enter the option(s) to remove (comma-separated): " options_to_remove
        options_to_remove=$(sanitize_input "$options_to_remove")
        IFS=',' read -ra options_array <<< "$options_to_remove"
        for option in "${options_array[@]}"; do
            share_options[$directory]=$(echo "${share_options[$directory]}" | sed -E "s/,?$option(,|$)?//")
        done

        sudo sed -i "/^${directory} /s/\(.*\)\s\(.*\)/${directory} ${shares[$directory]}/" /etc/exports
        echo "$directory ${shares[$directory]}" | sudo tee -a /etc/exports > /dev/null
        sudo exportfs -ra
        log_message "${GREEN}Options removed from NFS share $directory.${NC}"
        echo "New options: ${share_options[$directory]}"
    else
        log_message "${RED}Share not found.${NC}"
    fi
}

# Function to remove specific options from an SMB share
remove_smb_share_options() {
    read -p "Enter the name of the SMB share to modify: " sharename
    sharename=$(sanitize_input "$sharename")
    if [ -n "${shares[$sharename]}" ]; then
        echo "Current options for $sharename: ${share_options[${shares[$sharename]}]}"
        read -p "Enter the option(s) to remove (comma-separated): " options_to_remove
        options_to_remove=$(sanitize_input "$options_to_remove")
        IFS=',' read -ra options_array <<< "$options_to_remove"
        for option in "${options_array[@]}"; do
            share_options[${shares[$sharename]}]=$(echo "${share_options[${shares[$sharename]}]}" | sed -E "s/,?$option(,|$)?//")
        done

        sudo sed -i "/^\[$sharename\]/,/^\[/s/^$option.*//" /etc/samba/smb.conf
        sudo systemctl restart $SMB_SERVICE
        log_message "${GREEN}Options removed from SMB share $sharename.${NC}"
        echo "New options: ${share_options[${shares[$sharename]}]}"
    else
        log_message "${RED}Share not found.${NC}"
    fi
}

# Function to remove an NFS share (with share_options handling)
remove_nfs_share() {
    read -p "Enter the full path of the share to remove: " directory
    directory=$(sanitize_input "$directory")
    if [ -n "${shares[$directory]}" ]; then
        unset shares[$directory]
        unset share_options[$directory]
        sudo sed -i "/^${directory} /d" /etc/exports
        sudo exportfs -ra
        log_message "${GREEN}NFS share $directory removed.${NC}"
    else
        log_message "${RED}Share not found.${NC}"
    fi
}

# Function to remove an SMB share (with share_options handling)
remove_smb_share() {
    read -p "Enter the name of the SMB share to remove: " sharename
    sharename=$(sanitize_input "$sharename")
    if [ -n "${shares[$sharename]}" ]; then
        unset shares[$sharename]
        unset share_options[${shares[$sharename]}]
        sudo sed -i "/^\[$sharename\]/,/^\[/d" /etc/samba/smb.conf
        sudo systemctl restart $SMB_SERVICE
        log_message "${GREEN}SMB share $sharename removed.${NC}"
    else
        log_message "${RED}Share not found.${NC}"
    fi
}

# Edit or add a new NFS share
edit_or_add_nfs_share() {
    if [ ${#shares[@]} -eq 0 ]; then
        setup_nfs_exports
    else
        echo "Existing shares:"
        for dir in "${!shares[@]}"; do
            echo "$dir: ${shares[$dir]}"
        done

        select action in "Edit existing share" "Add new share"; do
            if [ -n "$REPLY" ]; then
                case "$REPLY" in
                    1)
                        read -p "Enter the directory path of the share to edit: " directory
                        directory=$(sanitize_input "$directory")
                        if [ -n "${shares[$directory]}" ]; then
                            setup_nfs_exports
                        else
                            log_message "${RED}Share not found.${NC}"
                        fi
                        ;;
                    2)
                        setup_nfs_exports
                        ;;
                esac
                break
            else
                echo "Invalid choice."
            fi
        done
    fi
}

# Edit or add a new SMB share
edit_or_add_smb_share() {
    if [ ${#shares[@]} -eq 0 ]; then
        setup_smb_exports
    else
        echo "Existing shares:"
        for share in "${!shares[@]}"; do
            echo "$share: ${shares[$share]}"
        done

        select action in "Edit existing share" "Add new share"; do
            if [ -n "$REPLY" ]; then
                case "$REPLY" in
                    1)
                        read -p "Enter the name of the SMB share to edit: " sharename
                        sharename=$(sanitize_input "$sharename")
                        if [ -n "${shares[$sharename]}" ]; then
                            setup_smb_exports
                        else
                            log_message "${RED}Share not found.${NC}"
                        fi
                        ;;
                    2)
                        setup_smb_exports
                        ;;
                esac
                break
            else
                echo "Invalid choice."
            fi
        done
    fi
}

# Edit an existing NFS share interactively (modified)
edit_nfs_share() {
    echo "Existing shares:"
    for dir in "${!shares[@]}"; do
        echo "$dir: ${shares[$dir]} (Options: ${share_options[$dir]})"
    done

    read -p "Enter the full path of the share to edit: " directory
    directory=$(sanitize_input "$directory")
    if [ -n "${shares[$directory]}" ]; then
        current_network="${shares[$directory]}"
        current_filetype=$(echo "${share_options[$directory]}" | grep -oP 'rsize=\K\d+' | awk '{ if ($1 == 8192) print "normal files"; else if ($1 == 4096) print "music,documents,photos"; else print "movies/tv"; }')
        current_accessmode=$(echo "${share_options[$directory]}" | grep -q ',ro' && echo "read-only" || echo "read/write")
        current_custom_options=$(echo "${share_options[$directory]}" | sed -E "s/^rw,sync,no_subtree_check(,ro)?,//") # Extract custom options
        
        select action in "Edit network" "Edit file type" "Edit access mode" "Edit custom options"; do
            case $action in
                "Edit network")
                    network=$(get_network)
                    shares["$directory"]="$network(${share_options[$directory]})"
                    ;;
                "Edit file type")
                    select filetype in "normal files" "music" "documents" "photos" "movies/tv"; do
                        if [ -n "$REPLY" ]; then
                            filetype=$(sanitize_input "$filetype")
                            break
                        else
                            echo "Invalid choice. Please select a file type."
                        fi
                    done
                    share_options["$directory"]=$(optimize_nfs_options "$filetype" "$current_accessmode")
                    ;;
                "Edit access mode")
                    select accessmode in "read-only" "read/write"; do
                        if [ -n "$REPLY" ]; then
                            accessmode=$(sanitize_input "$accessmode")
                            break
                        else
                            echo "Invalid choice. Please select an access mode."
                        fi
                    done
                    share_options["$directory"]=$(optimize_nfs_options "$current_filetype" "$accessmode")
                    ;;
                "Edit custom options")
                    read -p "Enter new custom options (comma-separated, leave blank to keep existing): " new_custom_options
                    new_custom_options=$(sanitize_input "$new_custom_options")
                    if [ -n "$new_custom_options" ]; then 
                        if validate_nfs_options "$new_custom_options"; then
                            share_options["$directory"]="${current_accessmode},${new_custom_options}"
                        else
                            echo "Invalid options format or unsupported options. Skipping."
                        fi
                    fi
                    ;;
            esac
            break
        done

        echo "$directory $network(${share_options[$directory]})" | sudo tee -a /etc/exports > /dev/null
        sudo exportfs -ra
        sudo systemctl restart $NFS_SERVICE
        log_message "${GREEN}NFS share $directory updated successfully.${NC}"
    else
        log_message "${RED}Share not found.${NC}"
    fi
}

# Edit an existing SMB share interactively (modified)
edit_smb_share() {
    echo "Existing shares:"
    for share in "${!shares[@]}"; do
        echo "$share: ${shares[$share]} (Options: ${share_options[${shares[$share]}]})"
    done

    read -p "Enter the name of the SMB share to edit: " sharename
    sharename=$(sanitize_input "$sharename")
    if [ -n "${shares[$sharename]}" ]; then
        current_directory="${shares[$sharename]}"
        current_accessmode=$(grep -A 5 "[$sharename]" /etc/samba/smb.conf | grep -E "read only|writable" | awk '{print $NF}')
        current_custom_options=$(grep -A 5 "[$sharename]" /etc/samba/smb.conf | grep -vE "path|read only|writable" | sed 's/^ *//;s/ *$//')

        select action in "Edit directory" "Edit access mode" "Edit custom options"; do
            case $action in
                "Edit directory")
                    directory=$(get_shared_directory)
                    shares["$sharename"]="$directory"
                    ;;
                "Edit access mode")
                    select accessmode in "read-only" "read/write"; do
                        if [ -n "$REPLY" ]; then
                            accessmode=$(sanitize_input "$accessmode")
                            break
                        else
                            echo "Invalid choice. Please select an access mode."
                        fi
                    done
                    ;;
                "Edit custom options")
                    read -p "Enter new custom options (comma-separated, leave blank to keep existing): " new_custom_options
                    new_custom_options=$(sanitize_input "$new_custom_options")
                    if [ -n "$new_custom_options" ]; then
                        current_custom_options="$new_custom_options"
                    fi
                    ;;
            esac
            break
        done

        sudo sed -i "/^\[$sharename\]/,/^\[/c\\
[$sharename]\n\
path = $directory\n\
$current_accessmode\n\
$current_custom_options" /etc/samba/smb.conf

        sudo systemctl restart $SMB_SERVICE
        log_message "${GREEN}SMB share $sharename updated successfully.${NC}"
    else
        log_message "${RED}Share not found.${NC}"
    fi
}

# Check for open ports
check_ports() {
    local ports=(2049 111 137 138 139 445)
    for port in "${ports[@]}"; do
        if ! nc -zv "$(hostname -I | awk '{print $1}')" "$port"; then
            log_message "${RED}Port $port is not open. Ensure your router/firewall settings are correct.${NC}"
            exit 1
        fi
    done
    log_message "${GREEN}All necessary ports are open.${NC}"
}

# Uninstall previous configurations
uninstall_previous_configurations() {
    read -p "Do you want to uninstall previous configurations? (yes/no): " response
    case $response in
        [Yy]*)
            sudo umount -a -t nfs,nfs4,cifs
            sudo rm -f /etc/exports
            sudo sed -i '/\[.*\]/,/^\[/d' /etc/samba/smb.conf
            log_message "${GREEN}Previous configurations have been removed.${NC}"
            ;;
        [Nn]*)
            echo "Retaining previous configurations."
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
}

# Allow users to edit /etc/exports
edit_exports_file() {
    sudo nano /etc/exports
}

# Allow users to edit /etc/samba/smb.conf
edit_smb_conf_file() {
    sudo nano /etc/samba/smb.conf
}

# Display NFS and SMB status and configurations
display_status() {
    echo "NFS Server Status:"
    sudo systemctl status $NFS_SERVICE
    echo "Exported directories:"
    sudo exportfs -v
    echo "Mounted NFS shares:"
    mount -t nfs
    echo "SMB Server Status:"
    sudo systemctl status $SMB_SERVICE
    echo "SMB Shares:"
    sudo testparm -s
    echo "Mounted SMB shares:"
    mount -t cifs
}

# Backup /etc/exports and /etc/samba/smb.conf files
backup_exports_file() {
    sudo cp /etc/exports /etc/exports.bak
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    log_message "${GREEN}/etc/exports and /etc/samba/smb.conf files backed up.${NC}"
}

# Restore /etc/exports and /etc/samba/smb.conf files
restore_exports_file() {
    if [ -f /etc/exports.bak ]; then
        sudo cp /etc/exports.bak /etc/exports
        sudo exportfs -ra
    fi
    if [ -f /etc/samba/smb.conf.bak ]; then
        sudo cp /etc/samba/smb.conf.bak /etc/samba/smb.conf
        sudo systemctl restart $SMB_SERVICE
    fi
    log_message "${GREEN}/etc/exports and /etc/samba/smb.conf files restored.${NC}"
}

# Control NFS and SMB server services
control_nfs_smb_services() {
    select action in "Start NFS and SMB Servers" "Stop NFS and SMB Servers" "Restart NFS and SMB Servers"; do
        case $action in
            "Start NFS and SMB Servers")
                if ! sudo systemctl start $NFS_SERVICE && sudo systemctl start $SMB_SERVICE; then
                    log_message "${RED}Error starting NFS and SMB services.${NC}"
                    exit 1
                fi
                log_message "${GREEN}NFS and SMB services started.${NC}"
                ;;
            "Stop NFS and SMB Servers")
                if ! sudo systemctl stop $NFS_SERVICE && sudo systemctl stop $SMB_SERVICE; then
                    log_message "${RED}Error stopping NFS and SMB services.${NC}"
                    exit 1
                fi
                log_message "${GREEN}NFS and SMB services stopped.${NC}"
                ;;
            "Restart NFS and SMB Servers")
                if ! sudo systemctl restart $NFS_SERVICE && sudo systemctl restart $SMB_SERVICE; then
                    log_message "${RED}Error restarting NFS and SMB services.${NC}"
                    exit 1
                fi
                log_message "${GREEN}NFS and SMB services restarted.${NC}"
                ;;
        esac
        break
    done
}

# Welcome message
welcome_message() {
    log_message "${GREEN}Welcome to the NFS and SMB Configuration Script!${NC}"
    log_message "This script helps you to set up and manage NFS and SMB server and client configurations."
    log_message "Please follow the instructions and choose the appropriate options as prompted."
}

# Main menu-driven interface
main_menu() {
    welcome_message
    determine_os_and_package_manager

    PS3="Select an option: "
    options=(
        "Install NFS Client" 
        "Install NFS Server" 
        "Install SMB Client"
        "Install SMB Server"
        "Display NFS and SMB Status"
        "Manage NFS Shares"
        "Manage SMB Shares"
        "Manage NFS and SMB Servers" 
        "Exit"
    )

    while true; do
        select opt in "${options[@]}"; do
            case $opt in
                "Install NFS Client")
                    install_nfs_client
                    setup_nfs_client
                    ;;
                "Install NFS Server")
                    install_nfs_server
                    configure_firewall
                    check_ports
                    uninstall_previous_configurations

                    while true; do
                        edit_or_add_nfs_share
                        read -p "Edit/add another share? (y/n): " choice
                        case "$choice" in
                            [yY]*) continue ;;
                            *) break ;;
                        esac
                    done

                    log_message "${GREEN}NFS server configuration complete.${NC}"
                    read -p "Do you want to edit /etc/exports manually? (yes/no): " manual_edit
                    case "$manual_edit" in
                        [yY]*) edit_exports_file ;;
                        *) log_message "Skipping manual edit of /etc/exports." ;;
                    esac
                    ;;
                "Install SMB Client")
                    install_smb_client
                    setup_smb_client
                    ;;
                "Install SMB Server")
                    install_smb_server
                    configure_firewall
                    check_ports
                    uninstall_previous_configurations

                    while true; do
                        edit_or_add_smb_share
                        read -p "Edit/add another share? (y/n): " choice
                        case "$choice" in
                            [yY]*) continue ;;
                            *) break ;;
                        esac
                    done

                    log_message "${GREEN}SMB server configuration complete.${NC}"
                    read -p "Do you want to edit /etc/samba/smb.conf manually? (yes/no): " manual_edit
                    case "$manual_edit" in
                        [yY]*) edit_smb_conf_file ;;
                        *) log_message "Skipping manual edit of /etc/samba/smb.conf." ;;
                    esac
                    ;;
                "Display NFS and SMB Status")
                    display_status
                    ;;
                "Manage NFS Shares")
                    PS3="Choose a share management option: "
                    select share_opt in "Edit existing share" "Remove NFS Share" "Remove Specific Options from NFS Share" "Back to Main Menu"; do
                        case $share_opt in
                            "Edit existing share")  edit_nfs_share  ;;
                            "Remove NFS Share")       remove_nfs_share ;;
                            "Remove Specific Options from NFS Share") remove_nfs_share_options ;;
                            "Back to Main Menu")     break ;;
                            *) log_message "${RED}Invalid option $REPLY${NC}";;
                        esac
                    done
                    ;;
                "Manage SMB Shares")
                    PS3="Choose a share management option: "
                    select share_opt in "Edit existing share" "Remove SMB Share" "Remove Specific Options from SMB Share" "Back to Main Menu"; do
                        case $share_opt in
                            "Edit existing share")  edit_smb_share  ;;
                            "Remove SMB Share")       remove_smb_share ;;
                            "Remove Specific Options from SMB Share") remove_smb_share_options ;;
                            "Back to Main Menu")     break ;;
                            *) log_message "${RED}Invalid option $REPLY${NC}";;
                        esac
                    done
                    ;;
                "Manage NFS and SMB Servers")
                    PS3="Choose an NFS and SMB server management option: "
                    select server_opt in "Control NFS and SMB Server Services" "Backup /etc/exports and /etc/samba/smb.conf" "Restore /etc/exports and /etc/samba/smb.conf" "Back to Main Menu"; do
                        case $server_opt in
                            "Control NFS and SMB Server Services") control_nfs_smb_services ;;
                            "Backup /etc/exports and /etc/samba/smb.conf") backup_exports_file ;;
                            "Restore /etc/exports and /etc/samba/smb.conf") restore_exports_file ;;
                            "Back to Main Menu") break ;;
                            *) log_message "${RED}Invalid option $REPLY${NC}";;
                        esac
                    done
                    ;;
                "Exit")
                    log_message "${GREEN}Exiting the script. Goodbye!${NC}"
                    break 2  # Break out of both the inner and outer loops
                    ;;
                *)
                    log_message "${RED}Invalid option $REPLY${NC}"
                    ;;
            esac
        done
    done  # Outer loop for main menu
}

# Run main menu
main_menu

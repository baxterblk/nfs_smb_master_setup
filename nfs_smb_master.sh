#!/bin/bash

NFS_SERVICE="nfs-server"
SMB_SERVICE="smbd"
PM=""
NFS_CLIENT_PKG="nfs-common"
SMB_CLIENT_PKG="cifs-utils"

declare -A shares
declare -A share_options

log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a setup.log
}

install_packages() {
    if [ -x "$(command -v apt-get)" ]; then
        PM="apt-get"
        sudo apt-get update
    elif [ -x "$(command -v yum)" ]; then
        PM="yum"
    elif [ -x "$(command -v dnf)" ]; then
        PM="dnf"
    else
        log_message "Package manager not found."
        exit 1
    fi

    if [ "$1" == "nfs" ]; then
        sudo $PM install -y nfs-kernel-server $NFS_CLIENT_PKG
    elif [ "$1" == "smb" ]; then
        sudo $PM install -y samba $SMB_CLIENT_PKG
    fi
}

sanitize_input() {
    local input="$1"
    input="${input//\\/\\\\}"
    input="${input//\'/\\\'}"
    input="${input//\"/\\\"}"
    echo "$input"
}

validate_username() {
    local username="$1"
    if [[ "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_directory() {
    local directory="$1"
    if [ -d "$directory" ]; then
        return 0
    else
        return 1
    fi
}

setup_nfs_server() {
    install_packages "nfs"
    while true; do
        directory=$(dialog --inputbox "Enter directory to share (absolute path):" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        if ! validate_directory "$directory"; then
            dialog --msgbox "Directory does not exist. Please enter a valid directory." 10 60
            continue
        fi
        network=$(dialog --inputbox "Enter network (e.g., 192.168.1.0/24):" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        file_type=$(dialog --inputbox "Enter file type (e.g., rw,sync,no_root_squash):" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        access_mode=$(dialog --inputbox "Enter access mode (e.g., ro or rw):" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        echo "$directory $network($file_type,$access_mode)" | sudo tee -a /etc/exports
        sudo exportfs -ra
        sudo systemctl daemon-reload
        sudo systemctl restart $NFS_SERVICE
        dialog --msgbox "NFS share $directory configured." 10 60
        break
    done
}

setup_nfs_client() {
    install_packages "nfs"
    while true; do
        server_ip=$(dialog --inputbox "Enter NFS server IP:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        remote_dir=$(dialog --inputbox "Enter remote directory to mount:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        local_dir=$(dialog --inputbox "Enter local directory to mount to:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        if ! validate_directory "$local_dir"; then
            create_dir=$(dialog --yesno "Local directory does not exist. Create it?" 10 60)
            if [ "$create_dir" == "0" ]; then
                sudo mkdir -p "$local_dir"
            else
                continue
            fi
        fi

        sudo mount -t nfs "$server_ip:$remote_dir" "$local_dir"
        dialog --msgbox "Mounted $server_ip:$remote_dir to $local_dir." 10 60
        add_fstab=$(dialog --yesno "Add to /etc/fstab for persistence?" 10 60)
        if [ "$add_fstab" == "0" ]; then
            echo "$server_ip:$remote_dir $local_dir nfs defaults 0 0" | sudo tee -a /etc/fstab
        fi
        break
    done
}

setup_smb_server() {
    install_packages "smb"
    while true; do
        directory=$(dialog --inputbox "Enter directory to share (absolute path):" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        if ! validate_directory "$directory"; then
            dialog --msgbox "Directory does not exist. Please enter a valid directory." 10 60
            continue
        fi

        share_name=$(dialog --inputbox "Enter share name:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        username=$(dialog --inputbox "Enter username:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        if ! validate_username "$username"; then
            dialog --msgbox "Invalid username. Only alphanumeric and underscores are allowed." 10 60
            continue
        fi

        password=$(dialog --passwordbox "Enter password:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        access_mode=$(dialog --inputbox "Enter access mode (e.g., read only = yes/no):" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        if grep -q "^\[$share_name\]" /etc/samba/smb.conf; then
            overwrite=$(dialog --yesno "Share name already exists. Overwrite?" 10 60)
            if [ "$overwrite" != "0" ]; then
                continue
            fi
            sudo sed -i "/^\[$share_name\]/,/^\[/d" /etc/samba/smb.conf
        fi

        echo -e "\n[$share_name]\n   path = $directory\n   browseable = yes\n   guest ok = no\n   read only = $access_mode\n   create mask = 0755" | sudo tee -a /etc/samba/smb.conf
        echo -e "$password\n$password" | sudo smbpasswd -a -s "$username"
        sudo systemctl daemon-reload
        sudo systemctl restart $SMB_SERVICE
        dialog --msgbox "SMB share $directory configured." 10 60
        break
    done
}

setup_smb_client() {
    install_packages "smb"
    while true; do
        server_ip=$(dialog --inputbox "Enter SMB server IP:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        share_name=$(dialog --inputbox "Enter remote share name:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        local_dir=$(dialog --inputbox "Enter local directory to mount to:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        username=$(dialog --inputbox "Enter username:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        password=$(dialog --passwordbox "Enter password:" 10 60 3>&1 1>&2 2>&3)
        [ $? -eq 1 ] && return

        if ! validate_directory "$local_dir"; then
            create_dir=$(dialog --yesno "Local directory does not exist. Create it?" 10 60)
            if [ "$create_dir" == "0" ]; then
                sudo mkdir -p "$local_dir"
            else
                continue
            fi
        fi

        sudo mount -t cifs "//$server_ip/$share_name" "$local_dir" -o username="$username",password="$password"
        dialog --msgbox "Mounted //$server_ip/$share_name to $local_dir." 10 60
        add_fstab=$(dialog --yesno "Add to /etc/fstab for persistence?" 10 60)
        if [ "$add_fstab" == "0" ]; then
            echo "//${server_ip}/${share_name} ${local_dir} cifs username=${username},password=${password},iocharset=utf8 0 0" | sudo tee -a /etc/fstab
        fi
        break
    done
}

edit_nfs_shares() {
    share=$(dialog --inputbox "Enter the share directory to edit:" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if ! grep -q "$share" /etc/exports; then
        dialog --msgbox "NFS share not found." 10 60
        return
    fi

    new_directory=$(dialog --inputbox "Enter new directory path (leave blank to keep current):" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if [ -n "$new_directory" ]; then
        sudo sed -i "s|$share|$new_directory|g" /etc/exports
    fi

    sudo exportfs -ra
    sudo systemctl daemon-reload
    sudo systemctl restart $NFS_SERVICE
    dialog --msgbox "NFS share updated." 10 60
}

edit_nfs_mounts() {
    mount_point=$(dialog --inputbox "Enter the local mount point to edit:" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if ! grep -q "$mount_point" /etc/fstab; then
        dialog --msgbox "NFS mount not found in /etc/fstab." 10 60
        return
    fi

    new_server_ip=$(dialog --inputbox "Enter new NFS server IP (leave blank to keep current):" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if [ -n "$new_server_ip" ]; then
        sudo sed -i "s|$(grep "$mount_point" /etc/fstab | awk '{print $1}')|$new_server_ip|g" /etc/fstab
    fi

    sudo mount -a
    dialog --msgbox "NFS mount updated." 10 60
}

edit_smb_shares() {
    share_name=$(dialog --inputbox "Enter the share name to edit:" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if ! grep -q "^\[$share_name\]" /etc/samba/smb.conf; then
        dialog --msgbox "SMB share not found." 10 60
        return
    fi

    new_directory=$(dialog --inputbox "Enter new directory path (leave blank to keep current):" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if [ -n "$new_directory" ]; then
        sudo sed -i "/^\[$share_name\]/,/^\[/s|^path = .*|path = $new_directory|g" /etc/samba/smb.conf
    fi

    sudo systemctl daemon-reload
    sudo systemctl restart $SMB_SERVICE
    dialog --msgbox "SMB share updated." 10 60
}

edit_smb_mounts() {
    mount_point=$(dialog --inputbox "Enter the local mount point to edit:" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if ! grep -q "$mount_point" /etc/fstab; then
        dialog --msgbox "SMB mount not found in /etc/fstab." 10 60
        return
    fi

    new_server_ip=$(dialog --inputbox "Enter new SMB server IP (leave blank to keep current):" 10 60 3>&1 1>&2 2>&3)
    [ $? -eq 1 ] && return

    if [ -n "$new_server_ip" ]; then
        sudo sed -i "s|$(grep "$mount_point" /etc/fstab | awk -F'/' '{print $3}')|$new_server_ip|g" /etc/fstab
    fi

    sudo mount -a
    dialog --msgbox "SMB mount updated." 10 60
}

show_readme() {
    dialog --textbox "README.md" 20 60
}

main_menu() {
    while true; do
        selection=$(dialog --menu "Main Menu" 15 50 8 \
            1 "NFS" \
            2 "SMB" \
            3 "Instructions" \
            4 "Exit" \
            2>&1 >/dev/tty)

        case $selection in
            1)
                while true; do
                    submenu=$(dialog --menu "NFS Menu" 15 50 6 \
                        1 "Setup NFS Server" \
                        2 "Setup NFS Client" \
                        3 "Edit NFS Shares" \
                        4 "Edit NFS Mounts" \
                        5 "Back" \
                        2>&1 >/dev/tty)

                    case $submenu in
                        1)
                            setup_nfs_server
                            ;;
                        2)
                            setup_nfs_client
                            ;;
                        3)
                            edit_nfs_shares
                            ;;
                        4)
                            edit_nfs_mounts
                            ;;
                        5)
                            break
                            ;;
                        *)
                            dialog --msgbox "Invalid selection. Please choose a valid option." 10 60
                            ;;
                    esac
                done
                ;;
            2)
                while true; do
                    submenu=$(dialog --menu "SMB Menu" 15 50 6 \
                        1 "Setup SMB Server" \
                        2 "Setup SMB Client" \
                        3 "Edit SMB Shares" \
                        4 "Edit SMB Mounts" \
                        5 "Back" \
                        2>&1 >/dev/tty)

                    case $submenu in
                        1)
                            setup_smb_server
                            ;;
                        2)
                            setup_smb_client
                            ;;
                        3)
                            edit_smb_shares
                            ;;
                        4)
                            edit_smb_mounts
                            ;;
                        5)
                            break
                            ;;
                        *)
                            dialog --msgbox "Invalid selection. Please choose a valid option." 10 60
                            ;;
                    esac
                done
                ;;
            3)
                show_readme
                ;;
            4)
                dialog --msgbox "Exiting the script." 10 60
                break
                ;;
            *)
                dialog --msgbox "Invalid selection. Please choose a valid option." 10 60
                ;;
        esac
    done
}

main_menu

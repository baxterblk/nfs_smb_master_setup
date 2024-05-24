# NFS and SMB Configuration Script

A user-friendly Bash script to simplify the setup and management of NFS (Network File System) and SMB (Server Message Block) shares on Linux systems (Red Hat and Debian based). It provides a menu-driven interface to automate various tasks.

## Features

- **OS Detection:** Automatically detects the operating system and uses the appropriate package manager (`dnf` or `apt`).

- **NFS Server Configuration:**
    - Installs necessary NFS server packages.
    - Sets up NFS exports with customizable options (file types, access modes, custom options).
    - Manages the NFS server service (start, stop, restart).
    - Configures the firewall to allow NFS traffic.
    - Allows manual editing of `/etc/exports`.
    - Backs up and restores `/etc/exports`.

- **NFS Client Configuration:**
    - Installs necessary NFS client packages.
    - Guides users through mounting remote NFS shares with optimized options.

- **SMB Server Configuration:**
    - Installs necessary SMB server packages.
    - Sets up SMB shares with customizable options.
    - Manages the SMB server service (start, stop, restart).
    - Allows manual editing of `/etc/samba/smb.conf`.
    - Backs up and restores `/etc/samba/smb.conf`.

- **SMB Client Configuration:**
    - Installs necessary SMB client packages.
    - Guides users through mounting remote SMB shares.

- **Additional Features:**
    - Uninstalls previous NFS/SMB configurations.
    - Removes specific options from NFS/SMB shares.
    - Checks for open ports required for NFS and SMB.
    - Displays the status of NFS and SMB services, exports, and shares.
    - Provides comprehensive logging of actions and errors to `/var/log/nfs_smb_config_script.log`.

## Prerequisites

- A Linux system (Red Hat or Debian based)
- `sudo` access
- Network connectivity between server and client (if configuring both)

## Usage

**Download:**
``curl -O https://raw.githubusercontent.com/baxterblk/nfs_smb_master_setup/main/nfs_smb_master.sh``

**Make Executable**
``chmod +x nfs_smb_config_script.sh``

**Run:**
``./nfs_smb_config_script.sh``

Follow the menu: Select the desired action.

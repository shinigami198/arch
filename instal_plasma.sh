#!/bin/bash
set -e

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "\e[${color}m${message}\e[0m"
}

# Function to handle errors
error_handler() {
    print_color "31" "Error occurred on line $1"
    exit 1
}

# Set up error handling
trap 'error_handler $LINENO' ERR

print_color "36" "Starting Arch Linux installation..."

loadkeys us
timedatectl set-ntp true
if [ $? -eq 0 ]; then
    print_color "32" "NTP synchronization enabled successfully."
else
    print_color "31" "Failed to enable NTP synchronization."
    exit 1
fi

print_color "33" "Configuring pacman..."
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf

# Enable multilib repository
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf

# Update pacman database
print_color "33" "Updating pacman database..."
pacman -Sy

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

print_color "33" "Updating mirror list..."
reflector -a 6 -c Singapore -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist

print_color "33" "Installing necessary packages..."
pacman -S --noconfirm --needed gptfdisk btrfs-progs glibc

umount -R /mnt 2>/dev/null || true

# Use gdisk to create the partitions
print_color "33" "Creating partitions..."
print_color "36" "Please enter the sizes for each partition."

read -p "Enter size for EFI partition (e.g., 1G): " efi_size
read -p "Enter size for root partition (e.g., 250G): " root_size
read -p "Enter size for swap partition (e.g., 4G): " swap_size

gdisk /dev/nvme0n1 << EOF
o
y
n
1

+${efi_size}
ef00
n
2

+${root_size}
8300
n
3


8200
w
y
EOF

# Format the partitions
print_color "33" "Formatting partitions..."
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.btrfs -f /dev/nvme0n1p2
mkswap /dev/nvme0n1p3

# Mount the partitions and create subvolumes
print_color "33" "Creating and mounting BTRFS subvolumes..."
mount /dev/nvme0n1p2 /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@snapshots

umount -R /mnt

# Updated mount options for better SSD performance
mount -o noatime,compress-force=zstd:3,ssd,space_cache=v2,discard=async,autodefrag,subvol=@ /dev/nvme0n1p2 /mnt
mount --mkdir -o noatime,compress-force=zstd:3,ssd,space_cache=v2,discard=async,autodefrag,subvol=@home /dev/nvme0n1p2 /mnt/home
mount --mkdir -o noatime,compress-force=zstd:3,ssd,space_cache=v2,discard=async,autodefrag,subvol=@log /dev/nvme0n1p2 /mnt/var/log
mount --mkdir -o noatime,compress-force=zstd:3,ssd,space_cache=v2,discard=async,autodefrag,subvol=@snapshots /dev/nvme0n1p2 /mnt/.snapshots

swapon /dev/nvme0n1p3

mount --mkdir /dev/nvme0n1p1 /mnt/boot/efi

choose_kernel() {
    while true; do
        echo "Please select a Linux kernel to install:"
        echo "1) linux"
        echo "2) linux-lts"
        echo "3) linux-zen"
        echo -n "Enter your choice [1-3]: "
        read choice
        case $choice in
            1) KERNEL="linux"; break;;
            2) KERNEL="linux-lts"; break;;
            3) KERNEL="linux-zen"; break;;
            *) echo "Invalid choice. Please choose again.";;
        esac
    done
}

# Call the function to choose a kernel
choose_kernel

KERNEL_HEADERS="${KERNEL}-headers"

# Now you can use the selected kernel with pacstrap
echo "Selected kernel: $KERNEL"

print_color "33" "Installing base system..."
pacstrap -K /mnt base base-devel $KERNEL $KERNEL_HEADERS linux-firmware sof-firmware networkmanager grub efibootmgr os-prober micro git wget

# Copy pacman configuration to the new system
print_color "33" "Copying pacman configuration to the new system..."
cp /etc/pacman.conf /mnt/etc/pacman.conf

print_color "33" "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

print_color "32" "Base system installation complete!"
print_color "33" "Please review /mnt/etc/fstab before rebooting."
print_color "36" "You can now chroot into the new system with: arch-chroot /mnt"

# Define additional functions and variables
EFI_PARTITION="/dev/nvme0n1p1"
BOOT_DISK="/dev/nvme0n1"
LABEL="Legion -- X"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
GRUB_CONF="/etc/default/grub"
GRUB_BACKUP_CONF="/etc/default/grub.bak"

# Set timezone and clock
ln -s /usr/share/zoneinfo/Asia/Kolkata /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc --utc

# Generate locale
arch-chroot /mnt sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
arch-chroot /mnt locale-gen
echo LANG=en_US.UTF-8 > /mnt/etc/locale.conf
echo KEYMAP=us > /mnt/etc/vconsole.conf
echo Legion-X > /mnt/etc/hostname

# Set password for root user
echo "Setting password for root user..."
arch-chroot /mnt passwd

# Create a new user
echo "Creating a new user..."
read -p "Enter the username for the new user: " NEW_USER
arch-chroot /mnt useradd -m -G wheel,storage,power -s /bin/bash "$NEW_USER"
echo "Setting password for $NEW_USER..."
arch-chroot /mnt passwd "$NEW_USER"

echo "User $NEW_USER has been created and added to the wheel group."

print_color "32" "Configuring sudoers..."
# Configure sudoers
arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Install GRUB
if [ -d "/sys/firmware/efi" ]; then
    print_color "32" "EFI system detected. Installing GRUB for EFI..."
    if ! mountpoint -q /mnt/boot/efi; then
        mkdir -p /mnt/boot/efi
        mount $EFI_PARTITION /mnt/boot/efi
    fi
    arch-chroot /mnt pacman -S --noconfirm efibootmgr
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$LABEL"
else
    print_color "32" "Legacy BIOS system detected. Installing GRUB for BIOS..."
    arch-chroot /mnt grub-install --target=i386-pc --bootloader-id="$LABEL" $BOOT_DISK
fi

# Check if GRUB installation was successful
if [ $? -eq 0 ]; then
    print_color "32" "GRUB installed successfully."
    arch-chroot /mnt pacman -S --noconfirm --needed os-prober
    echo "Enabling os-prober in GRUB configuration..."
    arch-chroot /mnt sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    echo "Generating GRUB configuration..."
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    if [ $? -eq 0 ]; then
        print_color "32" "GRUB configuration generated successfully."
    else
        print_color "31" "Failed to generate GRUB configuration."
        exit 1
    fi
else
    print_color "31" "Failed to install GRUB."
    exit 1
fi

# Update package database
arch-chroot /mnt pacman -Syy --noconfirm --needed

# Backup and modify mkinitcpio.conf
echo "Backing up $MKINITCPIO_CONF to $MKINITCPIO_CONF.bak"
arch-chroot /mnt cp "$MKINITCPIO_CONF" "$MKINITCPIO_CONF.bak"

if ! grep -q "btrfs" "$MKINITCPIO_CONF"; then
    echo "Adding btrfs module to mkinitcpio.conf"
    arch-chroot /mnt sed -i 's/^MODULES=(/MODULES=(btrfs /' "$MKINITCPIO_CONF"
fi
arch-chroot /mnt sed -i 's/fsck//' "$MKINITCPIO_CONF"

# NVIDIA GPU setup
read -p "Do you have an NVIDIA GPU? (y/n): " has_nvidia
if [[ $has_nvidia =~ ^[Yy]$ ]]; then
    print_color "32" "Installing NVIDIA drivers and configuring the system..."
    arch-chroot /mnt pacman -S --noconfirm --needed nvidia-dkms libglvnd opencl-nvidia nvidia-utils lib32-libglvnd lib32-opencl-nvidia lib32-nvidia-utils nvidia-settings nvidia-prime nvidia-prime-applet
    NVIDIA_MODULES=("nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm")

    for module in "${NVIDIA_MODULES[@]}"; do
        if ! grep -q "$module" "$MKINITCPIO_CONF"; then
            echo "Adding module $module to mkinitcpio.conf"
            arch-chroot /mnt sed -i "/^MODULES=(btrfs / s/$/ $module/" "$MKINITCPIO_CONF"
        fi
    done
    arch-chroot /mnt sed -i 's/kms//' "$MKINITCPIO_CONF"

    echo "Regenerating initramfs after adding NVIDIA modules"
    arch-chroot /mnt mkinitcpio -P

    echo "Backing up $GRUB_CONF to $GRUB_BACKUP_CONF"
    arch-chroot /mnt cp "$GRUB_CONF" "$GRUB_BACKUP_CONF"

    GRUB_PARAMS="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
    if ! grep -q "$GRUB_PARAMS" "$GRUB_CONF"; then
        echo "Adding parameters to GRUB_CMDLINE_LINUX_DEFAULT"
        arch-chroot /mnt sed -i "s/\(^GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $GRUB_PARAMS\"/" "$GRUB_CONF"
    fi
else
    print_color "33" "Skipping NVIDIA setup."
fi

# Prompt user to install SDDM
read -p "Do you want to install SDDM (Simple Desktop Display Manager)? (y/n): " install_sddm
if [[ $install_sddm =~ ^[Yy]$ ]]; then
    print_color "32" "Installing SDDM..."
    arch-chroot /mnt pacman -S --noconfirm sddm
    print_color "32" "Enabling SDDM service..."
    arch-chroot /mnt systemctl enable sddm

    # Prompt user to install Plasma
    read -p "Do you want to install Plasma (KDE Desktop Environment)? (y/n): " install_plasma
    if [[ $install_plasma =~ ^[Yy]$ ]]; then
        print_color "32" "Installing Plasma..."
        arch-chroot /mnt pacman -S --noconfirm plasma-desktop sddm-kcm plymouth-kcm kcm-fcitx flatpak-kcm

        # Install Flatpak and KDE Control Modules
        print_color "32" "Installing Flatpak and additional KDE Control Modules..."
        arch-chroot /mnt pacman -S --noconfirm flatpak kde-gtk-config breeze-gtk kdeconnect kdeplasma-addons bluez bluedevil kdisplay plasma-firewall plasma-browser-integration plasma-nm plasma-pa plasma-sdk plasma-systemmonitor power-profiles-daemon
        arch-chroot /mnt flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    else
        print_color "33" "Skipping Plasma installation."
    fi
else
    print_color "33" "Skipping SDDM installation."
fi

# Enable necessary services
print_color "32" "Enabling NetworkManager service..."
arch-chroot /mnt systemctl enable NetworkManager

print_color "32" "Enabling Bluetooth service..."
arch-chroot /mnt pacman -S --noconfirm bluez bluez-utils
arch-chroot /mnt systemctl enable bluetooth

# Modify GRUB configuration to enable Plymouth
print_color "32" "Modifying GRUB configuration to enable Plymouth..."
arch-chroot /mnt pacman -S --noconfirm plymouth
arch-chroot /mnt sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& quiet splash/' /etc/default/grub
arch-chroot /mnt sed -i 's/^#GRUB_GFXMODE=.*/GRUB_GFXMODE=auto/' /etc/default/grub
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

umount -R /mnt

reboot

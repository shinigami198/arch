# Define functions
print_color() {
    local color=$1
    local message=$2
    echo -e "\e[${color}m${message}\e[0m"
}

error_handler() {
    print_color "31" "Error occurred on line $1"
    exit 1
}

pause() {
    print_color "33" "Press any key to continue..."
    read -n 1 -s
    echo
}

# Trap errors and call error_handler
trap 'error_handler $LINENO' ERR

# Variables
EFI_PARTITION="/dev/nvme0n1p1"
BOOT_DISK="/dev/nvme0n1"
LABEL="Legion -- X"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
GRUB_CONF="/etc/default/grub"
GRUB_BACKUP_CONF="/etc/default/grub.bak"

# Set timezone and clock
ln -s /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc --utc

# Generate locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo KEYMAP=us > /etc/vconsole.conf
echo Legion-X > /etc/hostname

pause

# Set password for root user
echo "Setting password for root user..."
passwd
pause

# Create a new user
echo "Creating a new user..."
read -p "Enter the username for the new user: " NEW_USER
useradd -m -G wheel,storage,power -s /bin/bash "$NEW_USER"
echo "Setting password for $NEW_USER..."
passwd "$NEW_USER"
pause

echo "User $NEW_USER has been created and added to the wheel group."

print_color "32" "Configuring sudoers..."
# Configure sudoers
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

pause

# Install GRUB
if [ -d "/sys/firmware/efi" ]; then
    print_color "32" "EFI system detected. Installing GRUB for EFI..."
    if ! mountpoint -q /boot/efi; then
        mkdir -p /boot/efi
        mount $EFI_PARTITION /boot/efi
    fi
    pacman -S --noconfirm efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$LABEL"
else
    print_color "32" "Legacy BIOS system detected. Installing GRUB for BIOS..."
    grub-install --target=i386-pc --bootloader-id="$LABEL" $BOOT_DISK
fi
pause

# Check if GRUB installation was successful
if [ $? -eq 0 ]; then
    print_color "32" "GRUB installed successfully."
    pacman -S --noconfirm --needed os-prober
    echo "Enabling os-prober in GRUB configuration..."
    sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    echo "Generating GRUB configuration..."
    grub-mkconfig -o /boot/grub/grub.cfg
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
pause

# Update package database
pacman -Syy --noconfirm --needed

# Backup and modify mkinitcpio.conf
echo "Backing up $MKINITCPIO_CONF to $MKINITCPIO_CONF.bak"
cp "$MKINITCPIO_CONF" "$MKINITCPIO_CONF.bak"
pause

if ! grep -q "btrfs" "$MKINITCPIO_CONF"; then
    echo "Adding btrfs module to mkinitcpio.conf"
    sed -i 's/^MODULES=(/MODULES=(btrfs /' "$MKINITCPIO_CONF"
fi
sed -i 's/fsck//' "$MKINITCPIO_CONF"
pause

echo "Regenerating initramfs after mkinitcpio.conf modifications"
mkinitcpio -P
pause

# NVIDIA GPU setup
read -p "Do you have an NVIDIA GPU? (y/n): " has_nvidia
if [[ $has_nvidia =~ ^[Yy]$ ]]; then
    print_color "32" "Installing NVIDIA drivers and configuring the system..."
    pacman -S --noconfirm --needed nvidia-dkms libglvnd opencl-nvidia nvidia-utils lib32-libglvnd lib32-opencl-nvidia lib32-nvidia-utils
    NVIDIA_MODULES=("nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm")
    pause

    for module in "${NVIDIA_MODULES[@]}"; do
        if ! grep -q "$module" "$MKINITCPIO_CONF"; then
            echo "Adding module $module to mkinitcpio.conf"
            sed -i "s/^MODULES=(/MODULES=($module /" "$MKINITCPIO_CONF"
        fi
    done
    sed -i 's/kms//' "$MKINITCPIO_CONF"
    pause

    echo "Regenerating initramfs after adding NVIDIA modules"
    mkinitcpio -P
    pause

    echo "Backing up $GRUB_CONF to $GRUB_BACKUP_CONF"
    cp "$GRUB_CONF" "$GRUB_BACKUP_CONF"
    pause

    GRUB_PARAMS="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
    if ! grep -q "$GRUB_PARAMS" "$GRUB_CONF"; then
        echo "Adding parameters to GRUB_CMDLINE_LINUX_DEFAULT"
        sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/&$GRUB_PARAMS /" "$GRUB_CONF"
    fi
else
    print_color "33" "Skipping NVIDIA setup."
fi

echo "Updating GRUB configuration"
grub-mkconfig -o /boot/grub/grub.cfg
pause

if [ $? -eq 0 ]; then
    print_color "32" "GRUB configuration updated successfully."
    print_color "32" "Please reboot your system for changes to take effect."
else
    print_color "31" "Failed to update GRUB configuration."
    exit 1
fi

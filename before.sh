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

# Function to pause and wait for user input
pause() {
    print_color "33" "Press any key to continue..."
    read -n 1 -s
    echo
}

# Set up error handling
trap 'error_handler $LINENO' ERR

print_color "36" "Starting Arch Linux installation..."
pause

loadkeys us
set-ntp true

print_color "33" "Configuring pacman..."
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf

# Enable multilib repository
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf

# Update pacman database
print_color "33" "Updating pacman database..."
pacman -Sy
pause

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

print_color "33" "Updating mirror list..."
reflector -a 6 -c Singapore -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist
pause

print_color "33" "Installing necessary packages..."
pacman -S --noconfirm --needed gptfdisk btrfs-progs glibc
pause

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
pause

# Format the partitions
print_color "33" "Formatting partitions..."
mkfs.fat -F32 /dev/nvme0n1p1
mkfs.btrfs -f /dev/nvme0n1p2
mkswap /dev/nvme0n1p3
pause

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
pause

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
pause

print_color "33" "Installing base system..."
pacstrap -K /mnt base base-devel $KERNEL $KERNEL_HEADERS linux-firmware sof-firmware networkmanager grub efibootmgr os-prober micro git wget

# Copy pacman configuration to the new system
print_color "33" "Copying pacman configuration to the new system..."
cp /etc/pacman.conf /mnt/etc/pacman.conf
pause

print_color "33" "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
pause

print_color "32" "Base system installation complete!"
print_color "33" "Please review /mnt/etc/fstab before rebooting."
print_color "36" "You can now chroot into the new system with: arch-chroot /mnt"

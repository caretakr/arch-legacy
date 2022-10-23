#!/bin/sh

#
# Install
#

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: exiting..."; exit
fi

_log() {
    printf "▶ $1\n"
}

_main() {
    reset

    _log "Please provide the following:"

    printf "▶ Storage device: "; read _STORAGE_DEVICE

    if [ ! -b /dev/$_STORAGE_DEVICE ]; then
        _log "Storage device not found: exiting..."; exit
    fi

    printf "▶ Data password: "; read -s _DATA_PASSWORD && printf "\n"
    printf "▶ Data password confirmation: "; read -s _DATA_PASSWORD_CONFIRMATION && printf "\n"

    if [ "$_DATA_PASSWORD" != "$_DATA_PASSWORD_CONFIRMATION" ]; then
        _log "Data password mismatch: exiting..."; exit
    fi

    printf "▶ User password: "; read -s _USER_PASSWORD && printf "\n"
    printf "▶ User password confirmation: "; read -s _USER_PASSWORD_CONFIRMATION && printf "\n"

    if [ "$_USER_PASSWORD" != "$_USER_PASSWORD_CONFIRMATION" ]; then
        _log "User password mismatch: exiting..."; exit
    fi

    if [[ "$_STORAGE_DEVICE" = nvme* ]]; then
        _BOOT_PARTITION="${_STORAGE_DEVICE}p1"
        _SWAP_PARTITION="${_STORAGE_DEVICE}p2"
        _DATA_PARTITION="${_STORAGE_DEVICE}p3"
    else
        _BOOT_PARTITION="${_STORAGE_DEVICE}1"
        _SWAP_PARTITION="${_STORAGE_DEVICE}2"
        _DATA_PARTITION="${_STORAGE_DEVICE}3"
    fi

    _SWAP_SIZE="$(($(awk '( $1 == "MemTotal:" ) { printf "%3.0f", ($2/1000)*3 }' /proc/meminfo)*2048))"
    _DATA_START="$(($_SWAP_SIZE+2099200))"

    _log "Updating system clock..."

    timedatectl set-ntp true

    for m in \
        /mnt/boot \
        /mnt/root \
        /mnt/home/caretakr \
        /mnt/var/log \
        /mnt/var/lib/libvirt/images \
        /mnt \
    ; do
        if cat /proc/mounts | grep "$m" >/dev/null; then
            _log "Unmounting dangled "$m" mount..."

            umount "$m"
        fi
    done

    if [ -b /dev/mapper/$_DATA_PARTITION ]; then
        _log "Closing dangled encrypted device..."

        cryptsetup close $_DATA_PARTITION
    fi

    _log "Partitioning device..."

    sfdisk "/dev/$_STORAGE_DEVICE" <<EOF
label: gpt
device: /dev/$_STORAGE_DEVICE
unit: sectors
first-lba: 2048
sector-size: 512

/dev/$_BOOT_PARTITION: start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/dev/$_SWAP_PARTITION: start=2099200, size=$_SWAP_SIZE, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
/dev/$_DATA_PARTITION: start=$_DATA_START, size=, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

    _log "Waiting for disks syncing..."

    sleep 1

    _log "Encrypting data partition..."

    printf $_DATA_PASSWORD | cryptsetup luksFormat /dev/$_DATA_PARTITION -d -

    _log "Opening data partition..."

    printf $_DATA_PASSWORD | cryptsetup luksOpen /dev/$_DATA_PARTITION \
        $_DATA_PARTITION -d -

    _log "Formatting boot partition..."

    mkfs.fat -F 32 /dev/$_BOOT_PARTITION

    _log "Formatting swap partition..."

    mkswap /dev/$_SWAP_PARTITION

    _log "Formatting data partition..."

    mkfs.btrfs --checksum sha256 /dev/mapper/$_DATA_PARTITION

    _log "Mounting data partition..."

    mount /dev/mapper/$_DATA_PARTITION /mnt

    _log "Creating subvolume for base..."

    mkdir -p /mnt/base+snapshots
    btrfs subvolume create /mnt/base+live

    _log "Creating subvolume for root home..."

    mkdir -p /mnt/root+snapshots
    btrfs subvolume create /mnt/root+live

    _log "Creating subvolume for user home..."

    mkdir -p /mnt/home/caretakr+snapshots
    btrfs subvolume create /mnt/home/caretakr+live

    _log "Creating subvolume for logs..."

    mkdir -p /mnt/var/log+snapshots
    btrfs subvolume create /mnt/var/log+live

    _log "Creating subvolume for libvirt images..."

    mkdir -p /mnt/var/lib/libvirt/images+snapshots
    btrfs subvolume create /mnt/var/lib/libvirt/images+live

    _log "Unmouting data partition..."

    umount /mnt

    _log "Mounting base subvolume..."

    mount -o noatime,compress=zstd,subvol=base+live \
        /dev/mapper/$_DATA_PARTITION /mnt

    _log "Creating mount points..."

    mkdir -p /mnt/{boot,root,home/caretakr,var/lib/libvirt/images,var/log}

    _log "Mounting boot partition..."

    mount -o umask=0077 /dev/$_BOOT_PARTITION /mnt/boot

    _log "Mounting root home subvolume..."

    mount -o noatime,compress=zstd,subvol=root+live \
        /dev/mapper/$_DATA_PARTITION /mnt/root

    _log "Mounting user home subvolume..."

    mount -o noatime,compress=zstd,subvol=home/caretakr+live \
        /dev/mapper/$_DATA_PARTITION /mnt/home/caretakr

    _log "Mounting logs subvolume..."

    mount -o noatime,compress=zstd,subvol=var/log+live \
        /dev/mapper/$_DATA_PARTITION /mnt/var/log

    _log "Mounting libvirt images subvolume..."
        
    mount -o noatime,compress=zstd,subvol=var/lib/libvirt/images+live \
        /dev/mapper/$_DATA_PARTITION /mnt/var/lib/libvirt/images

    _log "Updating keyring..."

    pacman -Sy --noconfirm archlinux-keyring

    _log "Bootstrapping..."

    _PACMAN_PACKAGES=" \
        adwaita-qt5 \
        adwaita-qt6 \
        alsa-utils \
        base \
        base-devel \
        bluez \
        bluez-utils \
        bridge-utils \
        brightnessctl \
        bspwm \
        btop \
        btrfs-progs \
        chromium \
        dbeaver \
        dmidecode \
        dnsmasq \
        dosfstools \
        dunst \
        edk2-ovmf \
        efibootmgr \
        feh \
        firefox \
        firefox-developer-edition \
        firewalld \
        flatpak \
        fuse-overlayfs \
        fwupd \
        git \
        gnome-keyring \
        gnupg \
        gst-libav \
        gst-plugin-pipewire \
        gst-plugins-bad \
        gst-plugins-base \
        gst-plugins-good \
        gst-plugins-ugly \
        gstreamer \
        gstreamer-vaapi \
        gtk3 \
        gtk4 \
        helm \
        intel-ucode \
        iptables-nft \
        iwd \
        jq \
        kitty \
        kubectl \
        libfido2 \
        libnotify \
        libsecret \
        libvdpau-va-gl \
        libvirt \
        linux \
        linux-firmware \
        linux-headers \
        man \
        mate-polkit \
        mesa \
        minikube \
        mkinitcpio \
        mpv \
        noto-fonts \
        noto-fonts-cjk \
        noto-fonts-emoji \
        openbsd-netcat \
        openssh \
        openvpn \
        picom \
        pinentry \
        pipewire \
        pipewire-alsa \
        pipewire-jack \
        pipewire-pulse \
        playerctl \
        podman \
        podman-compose \
        podman-docker \
        polkit \
        polybar \
        qemu-full \
        qt5-base \
        qt6-base \
        redshift \
        rofi \
        rsync \
        rustup \
        seahorse \
        skaffold \
        slirp4netns \
        slock \
        sof-firmware \
        sudo \
        swtpm \
        sxhkd \
        systemd-resolvconf \
        telegram-desktop \
        tmux \
        trash-cli \
        udisks2 \
        unzip \
        vim \
        virt-manager \
        vulkan-intel \
        wireguard-tools \
        wireplumber \
        xdg-desktop-portal-gtk \
        xorg-server \
        xorg-xev \
        xorg-xinit \
        xorg-xinput \
        xorg-xrandr \
        xorg-xset \
        xss-lock \
        zsh
    "

    if \
        [ "$(dmidecode -s system-manufacturer)" = "Dell Inc." ] \
            && [ "$(dmidecode -s system-product-name)" = "XPS 13 9310" ]
    then
        _PACMAN_PACKAGES=" \
            $_PACMAN_PACKAGES \
            iio-sensor-proxy \
            intel-media-driver \
            sof-firmware \
        "
    fi

    if \
        [ "$(dmidecode -s system-manufacturer)" = "Apple Inc." ] \
            && [ "$(dmidecode -s system-product-name)" = "MacBookPro9,2" ]
    then
        _PACMAN_PACKAGES=" \
            $_PACMAN_PACKAGES \
            broadcom-wl \
            libva-intel-driver \
        "
    fi

    pacstrap /mnt $_PACMAN_PACKAGES

    _log "Setting file system table..."

    genfstab -U /mnt >> /mnt/etc/fstab

    _log "Setting timezone..."

    arch-chroot /mnt ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
    arch-chroot /mnt hwclock --systohc

    _log "Setting locale..."

    sed -i '/^#en_US.UTF-8 UTF-8/s/^#//g' /mnt/etc/locale.gen
    sed -i '/^#pt_BR.UTF-8 UTF-8/s/^#//g' /mnt/etc/locale.gen

    arch-chroot /mnt locale-gen

    _log "Setting language..."

    cat <<EOF > /mnt/etc/locale.conf
LANG=en_US.UTF-8
LANGUAGE=en_US.UTF-8
LC_ADDRESS=pt_BR.UTF-8
LC_COLLATE=en_US.UTF-8
LC_CTYPE=en_US.UTF-8
LC_IDENTIFICATION=pt_BR.UTF-8
LC_MEASUREMENT=pt_BR.UTF-8
LC_MESSAGES=en_US.UTF-8
LC_MONETARY=pt_BR.UTF-8
LC_NAME=pt_BR.UTF-8
LC_NUMERIC=pt_BR.UTF-8
LC_TELEPHONE=pt_BR.UTF-8
LC_TIME=pt_BR.UTF-8
LC_PAPER=pt_BR.UTF-8
EOF

    _log "Setting console..."

    if \
        [ "$(dmidecode -s system-manufacturer)" = "Dell Inc." ] \
            && [ "$(dmidecode -s system-product-name)" = "XPS 13 9310" \
    ]; then
        _KEYMAP="br-abnt2"
    fi

    if \
        [ "$(dmidecode -s system-manufacturer)" = "Apple Inc." ] \
            && [ "$(dmidecode -s system-product-name)" = "MacBookPro9,2" \
    ]; then
        _KEYMAP="us"
    fi

    cat <<EOF > /mnt/etc/vconsole.conf
KEYMAP=$_KEYMAP
EOF

    _log "Setting hosts..."

    cat <<EOF > /mnt/etc/hostname
arch
EOF

    cat <<EOF > /mnt/etc/hosts
127.0.0.1 localhost
127.0.1.1 arch.localdomain arch

::1 localhost
EOF

    _log "Setting network..."

    mkdir -p /mnt/etc/systemd/network

    cat <<EOF > /mnt/etc/systemd/network/20-ethernet.network
[Match]
Name=en*

[Network]
DHCP=yes

[DHCPv4]
RouteMetric=10

[IPv6AcceptRA]
RouteMetric=10
EOF

    cat <<EOF > /mnt/etc/systemd/network/25-wireless.network
[Match]
Name=wl*

[Network]
DHCP=yes

[DHCPv4]
RouteMetric=20

[IPv6AcceptRA]
RouteMetric=20
EOF

    _log "Setting sudoers..."

    cat <<EOF > /mnt/etc/sudoers.d/20-admin
%wheel ALL=(ALL:ALL) ALL
EOF

    cat <<EOF > /mnt/etc/sudoers.d/99-install
ALL ALL=(ALL:ALL) NOPASSWD: ALL
EOF

    _log "Setting user..."

    arch-chroot /mnt useradd -G wheel -m -s /bin/zsh caretakr
    arch-chroot /mnt chown caretakr:caretakr /home/caretakr
    arch-chroot /mnt chmod 0700 /home/caretakr

    touch /mnt/etc/subuid /mnt/etc/subgid
    
    arch-chroot /mnt usermod --add-subuids 100000-165535 \
        --add-subgids 100000-165535 caretakr

    echo "caretakr:$_USER_PASSWORD" | arch-chroot /mnt chpasswd

    _log "Setting home"...

    arch-chroot /mnt sudo -u caretakr sh -c \
        "(git clone https://github.com/caretakr/home.git /home/caretakr && cd /home/caretakr && git submodule init && git submodule update)"

    _log "Setting Paru..."

    arch-chroot /mnt sudo -u caretakr git clone \
        https://aur.archlinux.org/paru.git /var/tmp/paru

    arch-chroot /mnt sudo -u caretakr sh -c \
        "(cd /var/tmp/paru && makepkg -si --noconfirm && cd / && rm -rf /var/tmp/paru)"

    _log "Setting AUR packages..."

    _AUR_PACKAGES=" \
        plymouth-git \
    "

    for p in $_AUR_PACKAGES; do
        while ! arch-chroot /mnt sudo -u caretakr paru -S --noconfirm $p; do
            sleep 1
        done
    done

    _log "Setting ramdisk..."

    sed -i '/^MODULES/s/(.*)/(btrfs)/g' /mnt/etc/mkinitcpio.conf
    sed -i '/^HOOKS/s/(.*)/(base systemd sd-plymouth autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/g' /mnt/etc/mkinitcpio.conf

    arch-chroot /mnt mkinitcpio -P

    _log "Setting OOMD..."

    mkdir -p /mnt/etc/systemd/system/user@.service.d

    cat <<EOF > /mnt/etc/systemd/system/user@.service.d/override.conf
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
EOF

    mkdir -p /mnt/etc/systemd/system/-.slice.d

    cat <<EOF > /mnt/etc/systemd/system/-.slice.d/override.conf
[Slice]
ManagedOOMSwap=kill
EOF

    mkdir -p /mnt/etc/systemd/oomd.conf.d

    cat <<EOF > /mnt/etc/systemd/oomd.conf.d/override.conf
SwapUsedLimitPercent=90%
EOF

    _log "Setting NTP..."

    mkdir -p /mnt/etc/systemd/timesyncd.conf.d

    cat <<EOF > /mnt/etc/systemd/timesyncd.conf.d/override.conf
[Time]
NTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
EOF

    _log "Setting DNS..."

    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

    _log "Setting snapshots..."

    cat <<EOF > /mnt/usr/local/bin/snapshot
#
# Snapshot utility
#

if [ "\$EUID" -ne 0 ]; then
    echo "Please run as root"; exit 1
fi

_main() {
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            -d) _DEVICE="\$2"; shift 2;;
            -f) _FILESYSTEM="\$2"; shift 2;;
            -l) _LOCATION="\$2"; shift 2;;
            -p) _PROFILE="\$2"; shift 2;;
            -r) _RETENTION="\$2"; shift 2;;
            -t) _TAG="\$2"; shift 2;;

            --device=*) _DEVICE="\${1#*=}"; shift 1;;
            --filesystem=*) _FILESYSTEM="\${1#*=}"; shift 1;;
            --location=*) _LOCATION="\${1#*=}"; shift 1;;
            --profile=*) _PROFILE="\${1#*=}"; shift 1;;
            --retention=*) _RETENTION="\${1#*=}"; shift 1;;
            --tag=*) _TAG="\${1#*=}"; shift 1;;
            
            --device|--filesystem|--location|--profile|--retention|--tag)
                echo "\$1 requires an argument" >&2; exit 1;;
            
            -*) echo "unknown option: \$1" >&2; exit 1;;
            *) handle_argument "\$1"; shift 1;;
        esac
    done

    if [ -z "\$_DEVICE" ]; then
        echo "Device missing" >&2; exit 1;
    fi

    if [ -z "\$_FILESYSTEM" ]; then
        echo "Filesystem missing" >&2; exit 1;
    fi

    if [ -z "\$_LOCATION" ]; then
        echo "Location missing" >&2; exit 1;
    fi

    if [ -z "\$_PROFILE" ] && [ ! -z "\$_RETENTION" ] || [ ! -z "\$_TAG" ]; then
        echo "Profile missing" >&2; exit 1;
    fi

    if [ -z "\$_PROFILE" ] && [ -z "\$_RETENTION" ]; then
        echo "Retention missing" >&2; exit 1;
    fi

    if [ -z "\$_PROFILE" ] && [ -z "\$_TAG" ]; then
        echo "Tag missing" >&2; exit 1;
    fi

    _WORKING_DIRECTORY="\$(mktemp -d)"

    case "\$_PROFILE" in
        hourly) _RETENTION="24"; _TAG="hourly"; shift 2;;
        daily) _RETENTION="7"; _TAG="daily"; shift 2;;
        weekly) _RETENTION="4"; _TAG="weekly"; shift 2;;
        monthly) _RETENTION="3"; _TAG="monthly"; shift 2;;
    esac

    mount -o noatime,compress=zstd "\$_DEVICE" "\$_WORKING_DIRECTORY"

    if \
        btrfs subvolume snapshot -r "\$_FILESYSTEM" \\
            "\$_WORKING_DIRECTORY/\$_LOCATION+snapshots/\$(date --utc +%Y%m%dT%H%M%SZ)+\$_TAG"
    then
        sudo -u caretakr \\
            DISPLAY=:0 \\
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
            notify-send -u normal "Snapshot created" \\
            "A snapshot of \$_FILESYSTEM subvolume was created"
    else
        sudo -u caretakr \\
            DISPLAY=:0 \\
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
            notify-send -u critical "Snapshot failed" \\
            "A snapshot of \$_FILESYSTEM subvolume was failed"
    fi

    _COUNT=1

    for s in \$(find \$_WORKING_DIRECTORY/\$_LOCATION+snapshots/*+\$_TAG -maxdepth 0 -type d -printf "%f\n" | sort -nr); do
        if [ "\$_COUNT" -gt "\$_RETENTION" ]; then
            if
                ! btrfs subvolume delete \\
                    "\$_WORKING_DIRECTORY/\$_LOCATION+snapshots/\$s"
            then
                sudo -u caretakr \\
                    DISPLAY=:0 \\
                    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
                    notify-send -u critical "Cannot delete snapshot" \\
                    "A snapshot of \$_FILESYSTEM subvolume cannot be deleted"
            fi
        fi

        _COUNT=\$((\$_COUNT+1))
    done

    umount "\$_WORKING_DIRECTORY"
    rm -rf "\$_WORKING_DIRECTORY"

}

_main \$@
EOF

    arch-chroot /mnt chmod 0755 /usr/local/bin/snapshot

    cat <<EOF > /mnt/etc/systemd/system/snapshot-base@.service
[Unit]
Description=%i snapshot of base subvolume

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/snapshot -d /dev/mapper/$_DATA_PARTITION -f / -l base -p %i

[Install]
Also=snapshot-base-%i.timer
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-root@.service
[Unit]
Description=%i snapshot of root subvolume

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/snapshot -d /dev/mapper/$_DATA_PARTITION -f /root -l root -p %i

[Install]
Also=snapshot-root-%i.timer
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-home-caretakr@.service
[Unit]
Description=%i snapshot of home/caretakr subvolume

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/snapshot -d /dev/mapper/$_DATA_PARTITION -f /home/caretakr -l home/caretakr -p %i

[Install]
Also=snapshot-home-caretakr-%i.timer
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-log@.service
[Unit]
Description=%i snapshot of var/log subvolume

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/snapshot -d /dev/mapper/$_DATA_PARTITION -f /var/log -l var/log -p %i

[Install]
Also=snapshot-var-log-%i.timer
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-lib-libvirt-images@.service
[Unit]
Description=%i snapshot of var/lib/libvirt/images subvolume

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/snapshot -d /dev/mapper/$_DATA_PARTITION -f /var/lib/libvirt/images -l var/lib/libvirt/images -p %i

[Install]
Also=snapshot-var-lib-libvirt-images-%i.timer
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-base-hourly.timer
[Unit]
Description=hourly snapshot of base subvolume

[Timer]
OnCalendar=* *-*-* *:00:00
Persistent=true
Unit=snapshot-base@hourly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-root-hourly.timer
[Unit]
Description=hourly snapshot of root subvolume

[Timer]
OnCalendar=* *-*-* *:00:00
Persistent=true
Unit=snapshot-root@hourly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-home-caretakr-hourly.timer
[Unit]
Description=hourly snapshot of home/caretakr subvolume

[Timer]
OnCalendar=* *-*-* *:00:00
Persistent=true
Unit=snapshot-home-caretakr@hourly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-log-hourly.timer
[Unit]
Description=hourly snapshot of var/log subvolume

[Timer]
OnCalendar=* *-*-* *:00:00
Persistent=true
Unit=snapshot-var-log@hourly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-lib-libvirt-images-hourly.timer
[Unit]
Description=hourly snapshot of var/lib/libvirt/images subvolume

[Timer]
OnCalendar=* *-*-* *:00:00
Persistent=true
Unit=snapshot-var-lib-libvirt-images@hourly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-base-daily.timer
[Unit]
Description=daily snapshot of base subvolume

[Timer]
OnCalendar=* *-*-* 00:00:00
Persistent=true
Unit=snapshot-base@daily.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-root-daily.timer
[Unit]
Description=daily snapshot of root subvolume

[Timer]
OnCalendar=* *-*-* 00:00:00
Persistent=true
Unit=snapshot-root@daily.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-home-caretakr-daily.timer
[Unit]
Description=daily snapshot of home/caretakr subvolume

[Timer]
OnCalendar=* *-*-* 00:00:00
Persistent=true
Unit=snapshot-home-caretakr@daily.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-log-daily.timer
[Unit]
Description=daily snapshot of var/log subvolume

[Timer]
OnCalendar=* *-*-* 00:00:00
Persistent=true
Unit=snapshot-var-log@daily.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-lib-libvirt-images-daily.timer
[Unit]
Description=daily snapshot of var/lib/libvirt/images subvolume

[Timer]
OnCalendar=* *-*-* 00:00:00
Persistent=true
Unit=snapshot-var-lib-libvirt-images@daily.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-base-weekly.timer
[Unit]
Description=weekly snapshot of base subvolume

[Timer]
OnCalendar=Sun *-*-* 00:00:00
Persistent=true
Unit=snapshot-base@weekly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-root-weekly.timer
[Unit]
Description=weekly snapshot of root subvolume

[Timer]
OnCalendar=Sun *-*-* 00:00:00
Persistent=true
Unit=snapshot-root@weekly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-home-caretakr-weekly.timer
[Unit]
Description=weekly snapshot of home/caretakr subvolume

[Timer]
OnCalendar=Sun *-*-* 00:00:00
Persistent=true
Unit=snapshot-home-caretakr@weekly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-log-weekly.timer
[Unit]
Description=weekly snapshot of var/log subvolume

[Timer]
OnCalendar=Sun *-*-* 00:00:00
Persistent=true
Unit=snapshot-var-log@weekly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-lib-libvirt-images-weekly.timer
[Unit]
Description=weekly snapshot of var/lib/libvirt/images subvolume

[Timer]
OnCalendar=Sun *-*-* 00:00:00
Persistent=true
Unit=snapshot-var-lib-libvirt-images@weekly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-base-monthly.timer
[Unit]
Description=monthly snapshot of base subvolume

[Timer]
OnCalendar=* *-*-01 00:00:00
Persistent=true
Unit=snapshot-base@monthly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-root-monthly.timer
[Unit]
Description=monthly snapshot of root subvolume

[Timer]
OnCalendar=* *-*-01 00:00:00
Persistent=true
Unit=snapshot-root@monthly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-home-caretakr-monthly.timer
[Unit]
Description=monthly snapshot of home/caretakr subvolume

[Timer]
OnCalendar=* *-*-01 00:00:00
Persistent=true
Unit=snapshot-home-caretakr@monthly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-log-monthly.timer
[Unit]
Description=monthly snapshot of var/log subvolume

[Timer]
OnCalendar=* *-*-01 00:00:00
Persistent=true
Unit=snapshot-var-log@monthly.service

[Install]
WantedBy=timers.target
EOF

    cat <<EOF > /mnt/etc/systemd/system/snapshot-var-lib-libvirt-images-monthly.timer
[Unit]
Description=monthly snapshot of var/lib/libvirt/images subvolume

[Timer]
OnCalendar=* *-*-01 00:00:00
Persistent=true
Unit=snapshot-var-lib-libvirt-images@monthly.service

[Install]
WantedBy=timers.target
EOF

    _log "Setting backups..."

    cat <<EOF > /mnt/usr/local/bin/backup
#
# Backup utility
#

if [ "\$EUID" -ne 0 ]; then
    echo "Please run as root"; exit 1
fi

_main() {
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            -d) _DEVICE="\$2"; shift 2;;
            -f) _FILESYSTEM="\$2"; shift 2;;
            -l) _LOCATION="\$2"; shift 2;;
            -p) _PROFILE="\$2"; shift 2;;
            -r) _RETENTION="\$2"; shift 2;;
            -t) _TAG="\$2"; shift 2;;

            --device=*) _DEVICE="\${1#*=}"; shift 1;;
            --filesystem=*) _FILESYSTEM="\${1#*=}"; shift 1;;
            --location=*) _LOCATION="\${1#*=}"; shift 1;;
            --profile=*) _PROFILE="\${1#*=}"; shift 1;;
            --retention=*) _RETENTION="\${1#*=}"; shift 1;;
            --tag=*) _TAG="\${1#*=}"; shift 1;;
            
            --device|--filesystem|--location|--profile|--retention|--tag)
                echo "\$1 requires an argument" >&2; exit 1;;
            
            -*) echo "unknown option: \$1" >&2; exit 1;;
            *) handle_argument "\$1"; shift 1;;
        esac
    done

    if [ -z "\$_DEVICE" ]; then
        echo "Device missing" >&2; exit 1;
    fi

    if [ -z "\$_FILESYSTEM" ]; then
        echo "Filesystem missing" >&2; exit 1;
    fi

    if [ -z "\$_LOCATION" ]; then
        echo "Location missing" >&2; exit 1;
    fi

    if [ -z "\$_PROFILE" ] && [ ! -z "\$_RETENTION" ] || [ ! -z "\$_TAG" ]; then
        echo "Profile missing" >&2; exit 1;
    fi

    if [ -z "\$_PROFILE" ] && [ -z "\$_RETENTION" ]; then
        echo "Retention missing" >&2; exit 1;
    fi

    if [ -z "\$_PROFILE" ] && [ -z "\$_TAG" ]; then
        echo "Tag missing" >&2; exit 1;
    fi

    _WORKING_DIRECTORY="\$(mktemp -d)"

    case "\$_PROFILE" in
        hourly) _RETENTION="24"; _TAG="hourly"; shift 2;;
        daily) _RETENTION="7"; _TAG="daily"; shift 2;;
        weekly) _RETENTION="4"; _TAG="weekly"; shift 2;;
        monthly) _RETENTION="3"; _TAG="monthly"; shift 2;;
    esac

    mount -o noatime,compress=zstd "\$_DEVICE" "\$_WORKING_DIRECTORY"

    if \
        btrfs subvolume snapshot -r "\$_FILESYSTEM" \\
            "\$_WORKING_DIRECTORY/\$_LOCATION+snapshots/\$(date --utc +%Y%m%dT%H%M%SZ)+\$_TAG"
    then
        sudo -u caretakr \\
            DISPLAY=:0 \\
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
            notify-send -u normal "Snapshot created" \\
            "A snapshot of \$_FILESYSTEM subvolume was created"
    else
        sudo -u caretakr \\
            DISPLAY=:0 \\
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
            notify-send -u critical "Snapshot failed" \\
            "A snapshot of \$_FILESYSTEM subvolume was failed"
    fi

    _COUNT=1

    for s in \$(find \$_WORKING_DIRECTORY/\$_LOCATION+snapshots/*+\$_TAG -maxdepth 0 -type d -printf "%f\n" | sort -nr); do
        if [ "\$_COUNT" -gt "\$_RETENTION" ]; then
            if
                ! btrfs subvolume delete \\
                    "\$_WORKING_DIRECTORY/\$_LOCATION+snapshots/\$s"
            then
                sudo -u caretakr \\
                    DISPLAY=:0 \\
                    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
                    notify-send -u critical "Cannot delete snapshot" \\
                    "A snapshot of \$_FILESYSTEM subvolume cannot be deleted"
            fi
        fi

        _COUNT=\$((\$_COUNT+1))
    done

    umount "\$_WORKING_DIRECTORY"
    rm -rf "\$_WORKING_DIRECTORY"

}

_main \$@
EOF

    arch-chroot /mnt chmod 0755 /usr/local/bin/backup

    cat <<EOF > /mnt/etc/systemd/system/backup@.service
[Unit]
Description=%i backup of system

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/backup -d /dev/mapper/$_DATA_PARTITION -f / -l base -p %i

[Install]
Also=backup-base-%i.timer
EOF

    _log "Setting bootloader..."

    arch-chroot /mnt bootctl install

    cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

    cat <<EOF > /mnt/boot/loader/entries/arch.conf
title Arch
linux /vmlinuz-linux
initrd /initramfs-linux.img
options rd.luks.name=$(blkid -s UUID -o value /dev/$_DATA_PARTITION)=$_DATA_PARTITION rd.luks.options=discard root=UUID=$(blkid -s UUID -o value /dev/mapper/$_DATA_PARTITION) rootflags=subvol=base+live rw quiet splash loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0 i915.enable_psr=0 i915.enable_fbc=1
EOF

    cat <<EOF > /mnt/boot/loader/entries/arch-fallback.conf
title Arch (fallback)
linux /vmlinuz-linux
initrd /initramfs-linux-fallback.img
options rd.luks.name=$(blkid -s UUID -o value /dev/$_DATA_PARTITION)=$_DATA_PARTITION rd.luks.options=discard root=UUID=$(blkid -s UUID -o value /dev/mapper/$_DATA_PARTITION) rootflags=subvol=base+live rw quiet splash loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0 i915.enable_psr=0 i915.enable_fbc=1
EOF

    _log "Setting clean boot..."

    arch-chroot /mnt touch /root/.hushlogin

    arch-chroot /mnt touch /home/caretakr/.hushlogin
    arch-chroot /mnt chown caretakr:caretakr /home/caretakr/.hushlogin

    arch-chroot /mnt setterm -cursor on >> /etc/issue

    cat <<EOF > /mnt/etc/sysctl.d/20-quiet.conf
kernel.printk = 3 3 3 3
EOF

    mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d

    cat <<EOF > /mnt/etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --skip-login --nonewline --noissue --autologin caretakr --noclear %I \$TERM
EOF

    _log "Setting Bluetooth sleep toggle..."

    cat <<EOF > /mnt/etc/systemd/system/bluetooth-sleep-toggle.service
[Unit]
Description=Toggle Bluetooth before/after sleep
Before=sleep.target
Before=suspend.target
Before=hybrid-sleep.target
Before=suspend-then-hibernate.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/usr/bin/bluetoothctl power off
ExecStop=/usr/bin/bluetoothctl power on

[Install]
WantedBy=sleep.target
WantedBy=suspend.target
WantedBy=hybrid-sleep.target
WantedBy=suspend-then-hibernate.target
EOF

    _log "Setting services and timers..."

    arch-chroot /mnt systemctl enable bluetooth.service
    arch-chroot /mnt systemctl enable firewalld.service
    arch-chroot /mnt systemctl enable fstrim.timer
    arch-chroot /mnt systemctl enable iwd.service
    arch-chroot /mnt systemctl enable libvirtd.service
    arch-chroot /mnt systemctl enable snapshot-base-hourly.timer
    arch-chroot /mnt systemctl enable snapshot-base-daily.timer
    arch-chroot /mnt systemctl enable snapshot-root-hourly.timer
    arch-chroot /mnt systemctl enable snapshot-root-daily.timer
    arch-chroot /mnt systemctl enable snapshot-home-caretakr-hourly.timer
    arch-chroot /mnt systemctl enable snapshot-home-caretakr-daily.timer
    arch-chroot /mnt systemctl enable snapshot-var-log-hourly.timer
    arch-chroot /mnt systemctl enable snapshot-var-log-daily.timer
    arch-chroot /mnt systemctl enable snapshot-var-lib-libvirt-images-hourly.timer
    arch-chroot /mnt systemctl enable snapshot-var-lib-libvirt-images-daily.timer
    arch-chroot /mnt systemctl enable systemd-networkd.service
    arch-chroot /mnt systemctl enable systemd-oomd.service
    arch-chroot /mnt systemctl enable systemd-resolved.service
    arch-chroot /mnt systemctl enable systemd-timesyncd.service

    _log "Running user installation..."

    arch-chroot /mnt sudo -u caretakr sh -c \
        "/home/caretakr/.config/tools/install.sh"

    _log "Cleanup..."

    rm -f /mnt/etc/sudoers.d/99-install
}

_main "$@"
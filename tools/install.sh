#!/bin/sh

#
# Install
#

set -eu

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: exiting..."; exit
fi

INPUT=0
STEP=0

_log() {
  printf "%s\n" "$@"
}

_title() {
  printf '%s\n' "$1"

  for ((i=1;i<=${#1};i++)); do
    printf "%s" "-"
  done
  
  printf "\n\n"
}

_message() {
  printf '%s\n\n' "$@"
}

_input() {
  INPUT=$(($INPUT+1))

  printf "  %s) %s" "$INPUT" "$1"
}

_step() {
  STEP=$(($STEP+1))

  printf "\n" \
    && printf "%02d) %s\n" "$STEP" "$1"
}

_line() {
  for ((i=1;i<=$(tput cols);i++)); do
    printf "%s" "-"
  done

  printf "\n"
}

_main() {
  _title 'Arch system install'
  _message 'Please provide the following to begin installation of system:'

  _input 'Hostname: ' \
    && read _HOSTNAME

  _input 'Storage device: ' \
    && read _STORAGE_DEVICE

  if [ ! -b "/dev/$_STORAGE_DEVICE" ]; then
    _log 'Storage device not found: exiting...'; exit
  fi

  _input 'Data password: ' \
    && read -s _DATA_PASSWORD \
    && printf "\n"

  _input 'Data confirmation: ' \
    && read -s _DATA_CONFIRMATION \
    && printf "\n"

  if [ "$_DATA_PASSWORD" != "$_DATA_CONFIRMATION" ]; then
    _log "Data password mismatch: exiting..."; exit
  fi

  _input 'User password: ' \
    && read -s _USER_PASSWORD \
    && printf "\n"

  _input 'User confirmation: ' \
    && read -s _USER_CONFIRMATION \
    && printf "\n"

  if [ "$_USER_PASSWORD" != "$_USER_CONFIRMATION" ]; then
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

  _BOOT_START="2048"
  _BOOT_SIZE="$((1*1024*2048))"

  _SWAP_START="$(($_BOOT_START+$_BOOT_SIZE))"
  _SWAP_SIZE="$((($(dmidecode -t 17 | grep "Size.*GB" | awk '{s+=$2} END {print s * 1024}')*3)*2048))"

  _DATA_START="$(($_SWAP_START+$_SWAP_SIZE))"

  _SUBVOLUMES="
    base \
    root \
    home/caretakr \
    var/log \
    var/lib/libvirt/images
  "

  _step 'Updating system clock...' \
    && _line

  (
    timedatectl set-ntp true \
      && timedatectl status
  )

  _step 'Cleaning dangling state...' \
    && _line

  (
    _MOUNTS="
      /mnt/boot \
    "

    for s in $_SUBVOLUMES; do
      if [ "$s" = "base" ]; then
        continue
      fi

      _MOUNTS="
        $_MOUNTS \
        /mnt/$s
      "
    done

    _MOUNTS="
      $_MOUNTS \
      /mnt
    "

    for m in $_MOUNTS; do
      if cat /proc/mounts | grep "$m" >/dev/null; then
        _log "Unmounting dangled $m mount..."

        umount "$m"
      fi
    done

    if [ -b /dev/mapper/root ]; then
      _log 'Closing dangled encrypted device...'

      cryptsetup close root
    fi
  )

  _step 'Partitioning device...' \
    && _line

  (
    sfdisk "/dev/$_STORAGE_DEVICE" <<EOF
  label: gpt
  device: /dev/$_STORAGE_DEVICE
  unit: sectors
  first-lba: 2048
  sector-size: 512

  /dev/$_BOOT_PARTITION: start=$_BOOT_START, size=$_BOOT_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  /dev/$_SWAP_PARTITION: start=$_SWAP_START, size=$_SWAP_SIZE, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
  /dev/$_DATA_PARTITION: start=$_DATA_START, size=, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

    sleep 1
  )

  _step 'Encrypting partitions...' \
    && _line

  (
    printf "$_DATA_PASSWORD" | cryptsetup luksFormat \
        "/dev/$_DATA_PARTITION" -d - \
      && printf "$_DATA_PASSWORD" | cryptsetup luksOpen \
          "/dev/$_DATA_PARTITION" root -d -
  )

  _step 'Formatting partitions...' \
    && _line

  (
    mkfs.fat -F 32 "/dev/$_BOOT_PARTITION" \
      && mkswap "/dev/$_SWAP_PARTITION" \
      && mkfs.btrfs /dev/mapper/root
  )

  _step 'Mounting partitions...' \
    && _line

  (
    mount /dev/mapper/root /mnt

    for s in $_SUBVOLUMES; do
      mkdir -p "/mnt/$s+snapshots" \
        && btrfs subvolume create "/mnt/$s+live"
    done

    umount /mnt
  )

  _step 'Mounting subvolumes...' \
    && _line

  (
    mount -o rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=base+live \
        /dev/mapper/root /mnt \
      && mkdir -p /mnt/boot \
      && mount "/dev/$_BOOT_PARTITION" /mnt/boot

    for s in $_SUBVOLUMES; do
      if [ "$s" = 'base' ]; then
        continue
      fi

      mkdir -p "/mnt/$s" \
        && mount -o \
            "rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=$s+live" \
            /dev/mapper/root "/mnt/$s"
    done
  )

  _step 'Fixing permissions...' \
    && _line

  (
    chmod 750 /mnt/root \
      && chmod 750 /mnt/home/caretakr
  )

  _step 'Bootstrapping system...' \
    && _line

  (
    _PACMAN_PACKAGES=" \
      alsa-plugins \
      alsa-utils \
      base \
      bluez \
      bluez-utils \
      brightnessctl \
      btrfs-progs \
      dosfstools \
      efibootmgr \
      fwupd \
      git \
      gst-libav \
      gst-plugin-pipewire \
      gst-plugins-bad \
      gst-plugins-base \
      gst-plugins-good \
      gst-plugins-ugly \
      gstreamer \
      gstreamer-vaapi \
      intel-ucode \
      iwd \
      libgcrypt \
      linux \
      linux-firmware \
      man \
      mesa \
      pipewire \
      pipewire-alsa \
      pipewire-jack \
      pipewire-pulse \
      sof-firmware \
      sudo \
      udisks2 \
      vulkan-intel \
      wireplumber \
      zsh
    "

    if \
      [ "$(dmidecode -s system-manufacturer)" = 'Dell Inc.' ] \
        && [ "$(dmidecode -s system-product-name)" = 'XPS 13 9310' ]
    then
      _PACMAN_PACKAGES=" \
        $_PACMAN_PACKAGES \
        iio-sensor-proxy \
        intel-media-driver \
      "
    fi

    if \
      [ "$(dmidecode -s system-manufacturer)" = 'Apple Inc.' ] \
        && [ "$(dmidecode -s system-product-name)" = 'MacBookPro9,2' ]
    then
      _PACMAN_PACKAGES=" \
        $_PACMAN_PACKAGES \
        broadcom-wl \
        libva-intel-driver \
      "
    fi

    pacstrap -K /mnt $_PACMAN_PACKAGES
  )

  _step 'Setting filesystem...' \
    && _line

  (
    genfstab -U /mnt | sed -e 's/subvolid=[0-9]\+,//g' >> /mnt/etc/fstab
  )

  _step 'Setting timezone...' \
    && _line

  (
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/America/Sao_Paulo \
        /etc/localtime \
      && arch-chroot /mnt hwclock --systohc
  )

  _step "Setting locale..." \
    && _line

  (
    arch-chroot /mnt sed -i '/^#en_US.UTF-8 UTF-8/s/^#//g' /etc/locale.gen \
      && arch-chroot /mnt sed -i '/^#pt_BR.UTF-8 UTF-8/s/^#//g' /etc/locale.gen \
      && arch-chroot /mnt locale-gen
  )

  _step 'Setting language...' \
    && _line

  (
    _log 'Writing /etc/locale.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/locale.conf
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
  )

  _step 'Setting console...' \
    && _line

  (
    _KEYMAP='us'

    if \
      [ "$(dmidecode -s system-manufacturer)" = 'Dell Inc.' ] \
        && [ "$(dmidecode -s system-product-name)" = 'XPS 13 9310' \
    ]; then
      _KEYMAP='br-abnt2'
    fi

    _log 'Writing /etc/vconsole.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/vconsole.conf
KEYMAP=$_KEYMAP
EOF
  )

  _step 'Bootstrapping user...' \
    && _line

  (
    arch-chroot /mnt useradd -G wheel -m -s /bin/zsh caretakr \
      && arch-chroot /mnt chown caretakr:caretakr /home/caretakr \
      && arch-chroot /mnt chmod 0750 /home/caretakr

    echo "caretakr:$_USER_PASSWORD" | arch-chroot /mnt chpasswd

    arch-chroot /mnt sudo -u caretakr sh -c \
      "(git clone https://github.com/caretakr/home.git /home/caretakr && cd /home/caretakr && git submodule init && git submodule update)"
  )

  _step 'Setting sudo...' \
    && _line

  (
    _log 'Writing /etc/sudoers.d/20-admin:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/sudoers.d/20-admin
%wheel ALL=(ALL:ALL) ALL
EOF

    printf "\n"

    _log 'Writing /etc/sudoers.d/99-install:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/sudoers.d/99-install
ALL ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  )

  _step 'Setting network...' \
    && _line

  (
    _log 'Writing /etc/hostname:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/hostname
$_HOSTNAME
EOF

    printf "\n"

    _log 'Writing /etc/hosts:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/hosts
127.0.0.1 localhost
127.0.1.1 $_HOSTNAME.localdomain $_HOSTNAME

::1 localhost
EOF

    printf "\n"

    for i in \
      ethernet \
      wireless \
    ; do
      case "$i" in
          ethernet)
            _PRIORITY=20
            _NAME='en*'
            _METRIC=10

            ;;
          wireless)
            _PRIORITY=25
            _NAME='wl*'
            _METRIC=10

            ;;
      esac

      _log "Writing /etc/systemd/network/$_PRIORITY-$i.network:" \
        && printf "\n"

      cat <<EOF | arch-chroot /mnt tee /etc/systemd/network/$_PRIORITY-$i.network
[Match]
Name=$_NAME

[Network]
DHCP=yes

[DHCPv4]
RouteMetric=$_METRIC

[IPv6AcceptRA]
RouteMetric=$_METRIC
EOF

      printf "\n"
    done

    arch-chroot /mnt systemctl enable systemd-networkd.service
  )

  _step 'Setting Bluetooth...' \
    && _line

  (
    _log 'Writing /etc/systemd/system/bluetooth-toggle.service:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/system/bluetooth-toggle.service
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

    printf "\n"

    arch-chroot /mnt systemctl enable bluetooth.service \
      && arch-chroot /mnt systemctl enable bluetooth-toggle.service 
  )

  _step 'Setting OOMD...' \
    && _line

  (
    mkdir -p /mnt/etc/systemd/system/user@.service.d

    _log 'Writing /etc/systemd/system/user@.service.d/override.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/system/user@.service.d/override.conf
[Service]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
EOF

    printf "\n"

    mkdir -p /mnt/etc/systemd/system/-.slice.d

    _log 'Writing /etc/systemd/system/-.slice.d/override.conf:' \
        && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/system/-.slice.d/override.conf
[Slice]
ManagedOOMSwap=kill
EOF

    printf "\n"

    mkdir -p /mnt/etc/systemd/oomd.conf.d

    _log 'Writing /etc/systemd/oomd.conf.d/override.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/oomd.conf.d/override.conf
SwapUsedLimitPercent=90%
EOF

    printf "\n"

    arch-chroot /mnt systemctl enable systemd-oomd.service
  )

  _step 'Setting NTP...' \
    && _line

  (
    mkdir -p /mnt/etc/systemd/timesyncd.conf.d

    _log 'Writing /etc/systemd/timesyncd.conf.d/override.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/timesyncd.conf.d/override.conf
[Time]
NTP=pool.ntp.org time.nist.gov pool.ntp.br
FallbackNTP=time.google.com time.cloudflare.com time.facebook.com
EOF

    printf "\n"

    arch-chroot /mnt systemctl enable systemd-timesyncd.service
  )

  _step 'Setting DNS...' \
    && _line

  (
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf \
      && arch-chroot /mnt systemctl enable systemd-resolved.service
  )

  _step 'Setting BTRFS snapshots...' \
    && _line

  (
    _log 'Writing /usr/local/bin/btrfs-snapshot:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /usr/local/bin/btrfs-snapshot
#!/bin/sh

#
# BTRFS snapshot utility
#

if [ "\$EUID" -ne 0 ]; then
  echo "Please run as root"; exit 1
fi

_main() {
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      -d) _DEVICE="\$2"; shift 2;;
      -s) _SUBVOLUME="\$2"; shift 2;;
      -r) _RETENTION="\$2"; shift 2;;
      -t) _TAG="\$2"; shift 2;;

      --device=*) _DEVICE="\${1#*=}"; shift 1;;
      --subvolume=*) _SUBVOLUME="\${1#*=}"; shift 1;;
      --retention=*) _RETENTION="\${1#*=}"; shift 1;;
      --tag=*) _TAG="\${1#*=}"; shift 1;;

      --device|--subvolume|--retention|--tag)
        echo "\$1 requires an argument" >&2; exit 1;;

      -*) echo "unknown option: \$1" >&2; exit 1;;
      *) handle_argument "\$1"; shift 1;;
    esac
  done

  if [ -z "\$_DEVICE" ]; then
    echo "Device missing" >&2; exit 1;
  fi

  if [ -z "\$_SUBVOLUME" ]; then
    echo "Subvolume missing" >&2; exit 1;
  fi

  if [ -z "\$_RETENTION" ]; then
    echo "Retention missing" >&2; exit 1;
  fi

  if [ -z "\$_TAG" ]; then
    echo "Tag missing" >&2; exit 1;
  fi

  _WORKING_DIRECTORY="\$(mktemp -d)"

  mount -o noatime,compress=zstd "\$_DEVICE" "\$_WORKING_DIRECTORY"

  if \
    btrfs subvolume snapshot -r "\$_WORKING_DIRECTORY/\$_SUBVOLUME+live" \\
        "\$_WORKING_DIRECTORY/\$_SUBVOLUME+snapshots/\$(date --utc +%Y%m%dT%H%M%SZ)+\$_TAG"
  then
    sudo -u caretakr \\
        DISPLAY=:0 \\
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
        notify-send -u normal "Snapshot created" \\
        "A snapshot of \$_SUBVOLUME subvolume was created"
  else
    sudo -u caretakr \\
        DISPLAY=:0 \\
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
        notify-send -u critical "Snapshot failed" \\
        "A snapshot of \$_SUBVOLUME subvolume was failed"
  fi

  _COUNT=1

  for s in \$(find \$_WORKING_DIRECTORY/\$_SUBVOLUME+snapshots/*+\$_TAG -maxdepth 0 -type d -printf "%f\n" | sort -nr); do
    if [ "\$_COUNT" -gt "\$_RETENTION" ]; then
      if
        ! btrfs subvolume delete \\
            "\$_WORKING_DIRECTORY/\$_SUBVOLUME+snapshots/\$s"
      then
        sudo -u caretakr \\
            DISPLAY=:0 \\
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \\
            notify-send -u critical "Cannot delete snapshot" \\
            "A snapshot of \$_SUBVOLUME subvolume cannot be deleted"
      fi
    fi

    _COUNT=\$((\$_COUNT+1))
  done

  umount "\$_WORKING_DIRECTORY"
  rm -rf "\$_WORKING_DIRECTORY"
}

_main \$@
EOF

    printf "\n"

    arch-chroot /mnt chmod 0755 /usr/local/bin/btrfs-snapshot \
      && mkdir -p /mnt/etc/btrfs/snapshots

    for s in $_SUBVOLUMES; do
      for p in \
        hourly \
        daily \
      ; do
        case "$p" in
          hourly) _RETENTION=24 ;;
          daily) _RETENTION=7 ;;
        esac

        _log "Writing /etc/btrfs/snapshots/$(echo $s | sed "s/\//-/g")+$p.conf:" \
          && printf "\n"

        cat <<EOF | arch-chroot /mnt tee "/etc/btrfs/snapshots/$(echo $s | sed "s/\//-/g")+$p.conf"
DEVICE=/dev/mapper/root
SUBVOLUME=$s
RETENTION=$_RETENTION
TAG=$p
EOF

        printf "\n"
      done
    done

    _log 'Writing /etc/systemd/system/btrfs-snapshot@.service:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/system/btrfs-snapshot@.service
[Unit]
Description=BTRFS snapshot of %i subvolume

[Service]
Type=oneshot
EnvironmentFile=/etc/btrfs/snapshots/%i.conf
ExecStart=/bin/sh /usr/local/bin/btrfs-snapshot -d $DEVICE -s $SUBVOLUME -r $RETENTION -t $TAG
EOF

    for p in \
        hourly \
        daily \
    ; do
      case "$p" in
        hourly) _TIMER='* *-*-* *:00:00' ;;
        daily) _TIMER='* *-*-* 00:00:00' ;;
      esac

      printf "\n"

      _log "Writing /etc/systemd/system/btrfs-snapshot-$p@.timer:" \
        && printf "\n"

      cat <<EOF | arch-chroot /mnt tee "/etc/systemd/system/btrfs-snapshot-$p@.timer"
[Unit]
Description=$p BTRFS snapshot of %i subvolume

[Timer]
OnCalendar=$_TIMER
Persistent=true
Unit=btrfs-snapshot@%i+$p.service

[Install]
WantedBy=timers.target
EOF

      printf "\n"

      for s in $_SUBVOLUMES; do
        arch-chroot /mnt systemctl enable \
            "btrfs-snapshot-$p@$(echo $s | sed "s/\//-/g").timer"
      done
    done
  )

  printf "\n"

  _step 'Setting services...' \
    && _line

  (
    arch-chroot /mnt systemctl enable fstrim.timer
    arch-chroot /mnt systemctl enable iwd.service
  )

  _step 'Patching ramdisk...' \
    && _line

  (
    arch-chroot /mnt sed -i '/^MODULES/s/(.*)/(btrfs)/g' /etc/mkinitcpio.conf \
      && arch-chroot /mnt sed \
          -i '/^HOOKS/s/(.*)/(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/g' \
          /etc/mkinitcpio.conf

    arch-chroot /mnt mkinitcpio -P
  )

  _step 'Setting boot...' \
    && _line

  (
    arch-chroot /mnt bootctl install

    printf "\n"

    _log 'Writing /boot/loader/loader.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /boot/loader/loader.conf
default arch
EOF

    printf "\n"

    _log 'Writing /boot/loader/entries/arch.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /boot/loader/entries/arch.conf
title Arch
linux /vmlinuz-linux
initrd /initramfs-linux.img
options rd.luks.name=$(blkid -s UUID -o value /dev/$_DATA_PARTITION)=root rd.luks.options=discard root=UUID=$(blkid -s UUID -o value /dev/mapper/root) rootflags=subvol=base+live rw quiet splash loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0 i915.enable_psr=0 i915.enable_fbc=1
EOF

    printf "\n"

    _log 'Writing /boot/loader/entries/arch-fallback.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /boot/loader/entries/arch-fallback.conf
title Arch (fallback)
linux /vmlinuz-linux
initrd /initramfs-linux-fallback.img
options rd.luks.name=$(blkid -s UUID -o value /dev/$_DATA_PARTITION)=root rd.luks.options=discard root=UUID=$(blkid -s UUID -o value /dev/mapper/root) rootflags=subvol=base+live rw quiet splash loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0 i915.enable_psr=0 i915.enable_fbc=1
EOF

    printf "\n"

    arch-chroot /mnt touch /root/.hushlogin /home/caretakr/.hushlogin
    arch-chroot /mnt chown caretakr:caretakr /home/caretakr/.hushlogin
    arch-chroot /mnt setterm -cursor on >> /etc/issue

    _log 'Writing /etc/sysctl.d/20-quiet.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/sysctl.d/20-quiet.conf
kernel.printk = 3 3 3 3
EOF

    printf "\n"

    mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d

    _log 'Writing /etc/systemd/system/getty@tty1.service.d/override.conf:' \
      && printf "\n"

    cat <<EOF | arch-chroot /mnt tee /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --skip-login --nonewline --noissue --autologin caretakr --noclear %I \$TERM
EOF
  )

  printf "\n"

  _step 'Running user install...' \
    && _line

  printf "\n"

  (
    arch-chroot /mnt sudo -u caretakr sh -c \
      "/home/caretakr/.tools/install.sh"
  )

  _step 'Cleanup...' \
    && _line

  (
    rm -f /mnt/etc/sudoers.d/99-install
  )
}

reset

_main "$@"
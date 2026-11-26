#!/usr/bin/env bash
set -euo pipefail

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: Please run this script with sudo (e.g., sudo ./ubuntu-admin-install.sh)"
   exit 1
fi

# --- Interactive Prompts ---
read -r -p "Is this script being run on a desktop machine? (y/N): " IS_DESKTOP
USE_SDA="n"
IS_LAPTOP="n"

if [[ "$IS_DESKTOP" =~ ^[Yy]$ ]]; then
    read -r -p "Do you want all new user home folders stored on /dev/sda? (y/N): " USE_SDA
else
    read -r -p "Is this a laptop using wireless networking (configure per-user Wi-Fi auth)? (Y/n): " IS_LAPTOP
    IS_LAPTOP="${IS_LAPTOP:-Y}"
fi

echo "=== 1. Updating System & Installing Git + Docker Prerequisites ==="
apt-get update -y
apt-get install -y \
    git \
    ca-certificates \
    curl \
    uidmap \
    dbus-user-session \
    slirp4netns \
    fuse-overlayfs

echo "=== 2. Installing Official Docker Engine & Rootless Extras ==="
curl -fsSL https://get.docker.com | sh
apt-get install -y docker-ce-rootless-extras

echo "=== 3. Disabling System-Wide Root Daemon ==="
# Ensures students cannot access a shared root daemon and saves host RAM
systemctl disable --now docker.service docker.socket containerd.service || true

echo "=== 3b. Configuring AppArmor for RootlessKit (Ubuntu 24.04/26.04+) ==="
# Allows rootless Docker to create unprivileged user namespaces on first run
if command -v apparmor_parser >/dev/null 2>&1 && [[ -x /usr/bin/rootlesskit ]]; then
    cat << 'EOF' > /etc/apparmor.d/usr.bin.rootlesskit
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/usr.bin.rootlesskit>
}
EOF
    apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit || true
fi

echo "=== 4. Configuring /etc/skel for Future Student Accounts ==="
# Every new user created via adduser/useradd after this point inherits this setup
SKEL_BASHRC="/etc/skel/.bashrc"

if ! grep -q "DOCKER_HOST" "$SKEL_BASHRC"; then
cat << 'EOF' >> "$SKEL_BASHRC"

# --- Classroom Rootless Docker Configuration ---
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"

# Automatically initialize and start rootless Docker on first login if not yet configured
if [ "$(id -u)" -ge 1000 ] && [ ! -f "$HOME/.config/systemd/user/docker.service" ] && command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    echo "Initializing your personal Docker environment for the first time..."
    if dockerd-rootless-setuptool.sh install >/dev/null 2>&1; then
        systemctl --user enable --now docker.service >/dev/null 2>&1 || true
    else
        echo "Warning: Rootless Docker setup encountered an issue. Run 'dockerd-rootless-setuptool.sh install' to see details."
    fi
fi
EOF
fi

if [[ "$USE_SDA" =~ ^[Yy]$ ]]; then
    echo "=== 5. Configuring /dev/sda for New User Home Folders ==="
    MOUNT_POINT="/mnt/student_homes"

    # Detect whether /dev/sda1 exists; otherwise fall back to /dev/sda
    if [[ -b "/dev/sda1" ]]; then
        TARGET_DEV="/dev/sda1"
    elif [[ -b "/dev/sda" ]]; then
        TARGET_DEV="/dev/sda"
    else
        echo "Error: /dev/sda was not found on this system. Aborting drive configuration."
        exit 1
    fi

    # Verify the target device has a valid filesystem before mounting
    FS_TYPE=$(blkid -o value -s TYPE "$TARGET_DEV" || true)
    UUID=$(blkid -o value -s UUID "$TARGET_DEV" || true)

    if [[ -z "$FS_TYPE" || -z "$UUID" ]]; then
        echo "Error: $TARGET_DEV does not appear to have a formatted filesystem."
        echo "Please partition and format it first (e.g., sudo mkfs.ext4 /dev/sda1), then re-run."
        exit 1
    fi

    mkdir -p "$MOUNT_POINT"

    # Add persistent UUID mount to /etc/fstab if not already present
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID  $MOUNT_POINT  $FS_TYPE  defaults,nofail  0  2" >> /etc/fstab
    fi

    mount -a
    chmod 755 "$MOUNT_POINT"

    # Configure adduser (interactive Debian/Ubuntu tool) default home directory
    if grep -q "^DHOME=" /etc/adduser.conf; then
        sed -i "s|^DHOME=.*|DHOME=$MOUNT_POINT|" /etc/adduser.conf
    else
        echo "DHOME=$MOUNT_POINT" >> /etc/adduser.conf
    fi

    # Configure useradd (low-level/scripted tool) default home directory
    useradd -D -b "$MOUNT_POINT"

    echo "All new user home directories will now be created under $MOUNT_POINT ($TARGET_DEV)."
fi

if [[ "$IS_LAPTOP" =~ ^[Yy]$ ]]; then
    echo "=== 6. Configuring Per-User Wireless Network Authentication ==="

    # Ensure gnome-keyring is installed so each user's Wi-Fi credentials are stored in their personal keyring
    apt-get install -y gnome-keyring libsecret-1-0

    # Configure NetworkManager to store Wi-Fi & 802.1X secrets per-user (agent-owned, flags=1) instead of system-wide
    mkdir -p /etc/NetworkManager/conf.d
    cat << 'EOF' > /etc/NetworkManager/conf.d/99-per-user-wifi.conf
[connection]
wifi-security.psk-flags=1
802-1x.password-flags=1
EOF

    # Restrict non-admin users via Polkit so they can only create/modify their OWN connections, not system-wide ones
    mkdir -p /etc/polkit-1/rules.d
    cat << 'EOF' > /etc/polkit-1/rules.d/50-per-user-wifi.rules
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.NetworkManager.settings.modify.system" &&
        !subject.isInGroup("sudo") && !subject.isInGroup("netdev")) {
        return polkit.Result.NO;
    }
    if (action.id == "org.freedesktop.NetworkManager.settings.modify.own" &&
        subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
EOF

    # Scope any existing Wi-Fi profiles (e.g., setup Wi-Fi) strictly to the admin user who created them
    ADMIN_USER="${SUDO_USER:-root}"
    if command -v nmcli >/dev/null 2>&1; then
        while IFS=: read -r CONN_NAME CONN_TYPE; do
            if [[ "$CONN_TYPE" == "802-11-wireless" ]]; then
                echo "Restricting existing Wi-Fi profile '$CONN_NAME' to user '$ADMIN_USER'..."
                nmcli connection modify "$CONN_NAME" connection.permissions "user:${ADMIN_USER}" || true
            fi
        done < <(nmcli -t -f NAME,TYPE connection show)
    fi

    systemctl restart NetworkManager || true
    echo "Per-user wireless authentication configured. Each student will authenticate Wi-Fi under their own login."
fi

echo "=== Setup Complete! ==="

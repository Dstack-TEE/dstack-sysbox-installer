#!/bin/bash

set -e

echo "=========================================="
echo "🚀 Sysbox Complete Installer for dstack"
echo "=========================================="

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Helper function to run commands on host via nsenter
hostrun() {
    nsenter -t 1 -m -p -n "$@"
}

# Check if already installed
check_existing() {
    log_info "Checking existing installation..."

    # Check if systemd services exist (in either /etc or /run)
    if hostrun systemctl list-unit-files | grep -q "sysbox-mgr.service" ||
        [ -f /host/run/systemd/system/sysbox-mgr.service ] ||
        [ -f /host/etc/systemd/system/sysbox-mgr.service ]; then
        log_warning "Sysbox services already installed - skipping installation"

        # Show service status
        echo "Service status:"
        hostrun systemctl status sysbox-mgr.service --no-pager 2>/dev/null | head -5 || true
        hostrun systemctl status sysbox-fs.service --no-pager 2>/dev/null | head -5 || true

        # Check if actually running
        if hostrun systemctl is-active sysbox-mgr.service >/dev/null 2>&1; then
            log_success "Sysbox is installed and running"
        else
            log_info "Sysbox is installed but not running. Start with:"
            echo "  systemctl start sysbox-mgr sysbox-fs"
        fi

        log_info "To reinstall, first remove existing services:"
        echo "  systemctl stop sysbox-mgr sysbox-fs"
        echo "  systemctl disable sysbox-mgr sysbox-fs"
        echo "  rm /run/systemd/system/sysbox-*.service"
        echo "  systemctl daemon-reload"

        exit 0
    fi
}

# Copy binaries to host
copy_binaries() {
    log_info "Copying Sysbox binaries to host..."

    cp /usr/local/bin/rsync /host/usr/bin/
    cp /usr/local/bin/sysbox-* /host/usr/bin/
    chmod +x /host/usr/bin/rsync /host/usr/bin/sysbox-*

    # Create symlinks for dependencies
    hostrun ln -sf /usr/sbin/modprobe /usr/bin/modprobe 2>/dev/null || true
    hostrun ln -sf /usr/sbin/iptables /usr/bin/iptables 2>/dev/null || true

    # Handle fusermount/fusermount3 (Alpine has fusermount3, sysbox expects fusermount)
    if ! hostrun which fusermount >/dev/null 2>&1; then
        if hostrun which fusermount3 >/dev/null 2>&1; then
            log_info "Creating symlink: fusermount -> fusermount3"
            hostrun ln -sf /usr/bin/fusermount3 /usr/bin/fusermount
        else
            log_warning "Neither fusermount nor fusermount3 found - FUSE operations may fail"
        fi
    fi

    log_success "Binaries copied and dependencies linked"
}

setup_subuid_subgid() {
    log_info "Setting up subuid/subgid..."
    hostrun sh -c 'echo "sysbox:200000:65536" > /etc/subuid'
    hostrun sh -c 'echo "sysbox:200000:65536" > /etc/subgid'
    log_success "Created subuid/subgid mappings"
}

# Setup /etc overlay and configuration
setup_etc_overlay() {
    # Check if main overlay already exists
    if hostrun mount | grep -q " /etc .*overlay"; then
        log_warning "/etc already has overlay mounted - skipping mount"
        return
    fi

    log_info "Setting up /etc overlay..."

    # Create volatile overlay directories for /etc
    hostrun mkdir -p /var/volatile/overlay/etc/sysbox/upper /var/volatile/overlay/etc/sysbox/work

    # Preserve wireguard config if it exists in volatile storage
    if [ -f /host/var/volatile/overlay/etc/wireguard/upper/wg0.conf ]; then
        log_info "Preserving existing wireguard configuration..."
        mkdir -p /host/var/volatile/overlay/etc/sysbox/upper/wireguard
        cp /host/var/volatile/overlay/etc/wireguard/upper/* /host/var/volatile/overlay/etc/sysbox/upper/wireguard/ 2>/dev/null || true
    fi

    # Preserve docker config if it exists in volatile storage
    if [ -d /host/var/volatile/overlay/etc/docker/upper ]; then
        log_info "Preserving existing Docker configuration..."
        mkdir -p /host/var/volatile/overlay/etc/sysbox/upper/docker
        cp -r /host/var/volatile/overlay/etc/docker/upper/* /host/var/volatile/overlay/etc/sysbox/upper/docker/ 2>/dev/null || true
    fi

    # Unmount existing individual overlays (except /etc/users which should remain persistent)
    log_info "Unmounting individual overlays..."
    hostrun umount /etc/wireguard 2>/dev/null || true
    hostrun umount /etc/docker 2>/dev/null || true

    # Mount volatile /etc overlay
    hostrun mount -t overlay overlay \
        -o lowerdir=/etc,upperdir=/var/volatile/overlay/etc/sysbox/upper,workdir=/var/volatile/overlay/etc/sysbox/work \
        /etc
    log_success "Volatile /etc overlay mounted"

    # Remount /etc/users as persistent (if it exists) to override the volatile /etc mount
    if [ -d /host/dstack/persistent/overlay/etc/users ]; then
        log_info "Remounting /etc/users as persistent overlay..."
        hostrun mkdir -p /dstack/persistent/overlay/etc/users/upper /dstack/persistent/overlay/etc/users/work
        hostrun mount -t overlay overlay \
            -o lowerdir=/etc/users,upperdir=/dstack/persistent/overlay/etc/users/upper,workdir=/dstack/persistent/overlay/etc/users/work \
            /etc/users
        log_success "/etc/users mounted as persistent overlay"
    fi
}

# Configure Docker runtime
configure_docker() {
    log_info "Configuring Docker runtime..."

    # TODO: Implement proper JSON merging to preserve existing Docker configuration
    # Currently overwrites daemon.json - should merge with existing runtimes/settings

    # Backup existing daemon.json if it exists
    if hostrun [ -f /etc/docker/daemon.json ]; then
        hostrun cp /etc/docker/daemon.json /etc/docker/daemon.json.backup
        log_info "Backed up existing Docker daemon.json (will be overwritten)"
    fi

    hostrun tee /etc/docker/daemon.json >/dev/null <<'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "10"
  },
  "runtimes": {
    "sysbox-runc": {
      "path": "/usr/bin/sysbox-runc"
    }
  }
}
DOCKEREOF

    log_success "Docker configuration updated"
}

# Create systemd services
create_systemd_services() {
    log_info "Creating systemd services..."

    # Use /run/systemd/system for runtime units (doesn't require persistent storage)
    hostrun mkdir -p /run/systemd/system

    # Copy service files from container to host runtime directory
    cp /usr/local/share/sysbox-mgr.service /host/run/systemd/system/
    cp /usr/local/share/sysbox-fs.service /host/run/systemd/system/

    # Verify files were copied
    if [ ! -f /host/run/systemd/system/sysbox-mgr.service ]; then
        log_error "Failed to copy sysbox-mgr.service to /run/systemd/system/"
        return 1
    fi

    if [ ! -f /host/run/systemd/system/sysbox-fs.service ]; then
        log_error "Failed to copy sysbox-fs.service to /run/systemd/system/"
        return 1
    fi

    log_success "Service files copied to /run/systemd/system/"

    # Reload systemd to pick up new service files
    hostrun systemctl daemon-reload

    log_success "Systemd services created (transient until reboot)"
    log_info "Services: sysbox-mgr, sysbox-fs"
}

# Start Sysbox services
start_sysbox() {
    log_info "Starting Sysbox services..."

    # Create data directory
    hostrun mkdir -p /dstack/persistent/sysbox-data

    # Start services in order
    log_info "Starting Sysbox manager..."
    hostrun systemctl start sysbox-mgr.service
    sleep 3

    log_info "Starting Sysbox filesystem..."
    hostrun systemctl start sysbox-fs.service
    sleep 2

    # Verify services are running
    if hostrun systemctl is-active sysbox-mgr.service >/dev/null &&
        hostrun systemctl is-active sysbox-fs.service >/dev/null; then
        log_success "Sysbox services started successfully"
    else
        log_warning "Some services may not have started correctly"
        log_info "Check status with: systemctl status sysbox-mgr sysbox-fs"
        log_info "Check logs with: journalctl -u sysbox-mgr -u sysbox-fs"
    fi
}

# Display final status
show_status() {
    echo
    echo "=========================================="
    echo -e "${GREEN}🎉 Sysbox Installation Complete!${NC}"
    echo "=========================================="
    echo
    echo "📊 Status:"
    echo "  • Sysbox Manager: $(hostrun systemctl is-active sysbox-mgr.service)"
    echo "  • Sysbox FS:      $(hostrun systemctl is-active sysbox-fs.service)"
    echo "  • Docker Runtime: Configured (restart required)"
    echo
    echo -e "${YELLOW}⚠️  IMPORTANT: Restart Docker to enable sysbox-runc runtime:${NC}"
    echo -e "${GREEN}    systemctl restart docker${NC}"
    echo
    echo "🚀 Usage (after Docker restart):"
    echo "  docker run --runtime=sysbox-runc -it ubuntu bash"
    echo "  docker run --runtime=sysbox-runc -d docker:dind  # Docker-in-Docker"
    echo
    echo "🔧 Management:"
    echo "  systemctl status sysbox-mgr sysbox-fs    # Check status"
    echo "  systemctl restart sysbox-mgr sysbox-fs   # Restart services"
    echo "  journalctl -u sysbox-mgr -u sysbox-fs    # View logs"
    echo
    echo "📁 Data Location:"
    echo "  • Sysbox data: /dstack/persistent/sysbox-data"
    echo
}

# Main installation flow
main() {
    check_existing
    copy_binaries
    setup_etc_overlay
    setup_subuid_subgid
    configure_docker
    create_systemd_services
    start_sysbox
    show_status
}

# Run main function
main "$@"

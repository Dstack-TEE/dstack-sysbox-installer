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
host_run() {
    nsenter -t 1 -m -p -n "$@"
}

# Check if already installed
check_existing() {
    log_info "Checking existing installation..."

    # Check if systemd services exist (in either /etc or /run)
    if host_run systemctl list-unit-files | grep -q "sysbox-mgr.service" ||
        [ -f /host/run/systemd/system/sysbox-mgr.service ] ||
        [ -f /host/etc/systemd/system/sysbox-mgr.service ]; then
        log_warning "Sysbox services already installed - skipping installation"

        # Show service status
        echo "Service status:"
        host_run systemctl status sysbox-mgr.service --no-pager 2>/dev/null | head -5 || true
        host_run systemctl status sysbox-fs.service --no-pager 2>/dev/null | head -5 || true

        # Check if actually running
        if host_run systemctl is-active sysbox-mgr.service >/dev/null 2>&1; then
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
    host_run ln -sf /usr/sbin/modprobe /usr/bin/modprobe 2>/dev/null || true
    host_run ln -sf /usr/sbin/iptables /usr/bin/iptables 2>/dev/null || true

    # Handle fusermount/fusermount3 (Alpine has fusermount3, sysbox expects fusermount)
    if ! host_run which fusermount >/dev/null 2>&1; then
        if host_run which fusermount3 >/dev/null 2>&1; then
            log_info "Creating symlink: fusermount -> fusermount3"
            host_run ln -sf /usr/bin/fusermount3 /usr/bin/fusermount
        else
            log_warning "Neither fusermount nor fusermount3 found - FUSE operations may fail"
        fi
    fi

    log_success "Binaries copied and dependencies linked"
}

setup_subuid_subgid() {
    log_info "Setting up subuid/subgid..."
    host_run sh -c 'echo "sysbox:200000:65536" > /etc/subuid'
    host_run sh -c 'echo "sysbox:200000:65536" > /etc/subgid'
    log_success "Created subuid/subgid mappings"
}

# Setup /etc overlay and configuration
setup_etc_overlay() {
    # Check if main overlay already exists
    if host_run mount | grep -q " /etc .*overlay"; then
        log_warning "/etc already has overlay mounted - skipping mount"
        return
    fi

    log_info "Setting up /etc overlay..."

    # Create volatile overlay directories for /etc
    host_run mkdir -p /var/volatile/overlay/etc/sysbox/upper /var/volatile/overlay/etc/sysbox/work

    # Preserve wireguard config if it exists in volatile storage
    if host_run [ -f /var/volatile/overlay/etc/wireguard/upper/wg0.conf ]; then
        log_info "Preserving existing wireguard configuration..."
        host_run mkdir -p /var/volatile/overlay/etc/sysbox/upper/wireguard
        host_run bash -c 'cp /var/volatile/overlay/etc/wireguard/upper/* /var/volatile/overlay/etc/sysbox/upper/wireguard/ 2>/dev/null' || true
    fi

    # Preserve docker config if it exists in volatile storage
    if host_run [ -d /var/volatile/overlay/etc/docker/upper/daemon.json ]; then
        log_info "Preserving existing Docker configuration..."
        host_run mkdir -p /var/volatile/overlay/etc/sysbox/upper/docker
        host_run bash -c 'cp -r /var/volatile/overlay/etc/docker/upper/* /var/volatile/overlay/etc/sysbox/upper/docker/ 2>/dev/null' || true
    fi

    # Unmount existing individual overlays (except /etc/users which should remain persistent)
    log_info "Unmounting individual overlays..."
    host_run umount /etc/wireguard 2>/dev/null || true
    host_run umount /etc/docker 2>/dev/null || true

    # Mount volatile /etc overlay
    host_run mount -t overlay overlay \
        -o lowerdir=/etc,upperdir=/var/volatile/overlay/etc/sysbox/upper,workdir=/var/volatile/overlay/etc/sysbox/work \
        /etc
    log_success "Volatile /etc overlay mounted"

    # Remount /etc/users as persistent (if it exists) to override the volatile /etc mount
    if host_run [ -d /dstack/persistent/overlay/etc/users ]; then
        log_info "Remounting /etc/users as persistent overlay..."
        host_run mkdir -p /dstack/persistent/overlay/etc/users/upper /dstack/persistent/overlay/etc/users/work
        host_run mount -t overlay overlay \
            -o lowerdir=/etc/users,upperdir=/dstack/persistent/overlay/etc/users/upper,workdir=/dstack/persistent/overlay/etc/users/work \
            /etc/users
        log_success "/etc/users mounted as persistent overlay"
    fi
}

# Configure Docker runtime
configure_docker() {
    log_info "Configuring Docker runtime using Sysbox's docker-cfg script..."

    # Backup existing daemon.json if it exists
    if host_run [ -f /etc/docker/daemon.json ]; then
        host_run cp /etc/docker/daemon.json /etc/docker/daemon.json.backup
        log_info "Backed up existing Docker daemon.json"
    fi

    # Use Sysbox's official docker-cfg script to configure Docker
    cp /usr/local/bin/sysbox-docker-cfg /usr/bin/
    if host_run bash /usr/bin/sysbox-docker-cfg --sysbox-runtime=enable; then
        log_success "Docker configuration updated with Sysbox runtime"
    else
        log_error "Failed to configure Docker with docker-cfg script"
        if host_run [ -f /etc/docker/daemon.json.backup ]; then
            host_run mv /etc/docker/daemon.json.backup /etc/docker/daemon.json
            log_info "Restored backup Docker configuration"
        fi
        return 1
    fi

    log_success "Docker configuration completed"
}

# Create systemd services
create_systemd_services() {
    log_info "Creating systemd services..."

    # Use /run/systemd/system for runtime units (doesn't require persistent storage)
    host_run mkdir -p /run/systemd/system

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
    host_run systemctl daemon-reload

    log_success "Systemd services created (transient until reboot)"
    log_info "Services: sysbox-mgr, sysbox-fs"
}

# Start Sysbox services
start_sysbox() {
    log_info "Starting Sysbox services..."

    # Create data directory
    host_run mkdir -p /dstack/persistent/sysbox-data

    # Start services in order
    log_info "Starting Sysbox manager..."
    host_run systemctl start sysbox-mgr.service
    sleep 3

    log_info "Starting Sysbox filesystem..."
    host_run systemctl start sysbox-fs.service
    sleep 2

    # Verify services are running
    if host_run systemctl is-active sysbox-mgr.service >/dev/null &&
        host_run systemctl is-active sysbox-fs.service >/dev/null; then
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
    echo "  • Sysbox Manager: $(host_run systemctl is-active sysbox-mgr.service)"
    echo "  • Sysbox FS:      $(host_run systemctl is-active sysbox-fs.service)"
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

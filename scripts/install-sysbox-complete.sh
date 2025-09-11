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

# Check if already installed
check_existing() {
    log_info "Checking existing installation..."

    # Check if systemd services exist (in either /etc or /run)
    if chroot /host systemctl list-unit-files | grep -q "sysbox-mgr.service" ||
        [ -f /host/run/systemd/system/sysbox-mgr.service ] ||
        [ -f /host/etc/systemd/system/sysbox-mgr.service ]; then
        log_warning "Sysbox services already installed - skipping installation"

        # Show service status
        echo "Service status:"
        chroot /host systemctl status sysbox-mgr.service --no-pager 2>/dev/null | head -5 || true
        chroot /host systemctl status sysbox-fs.service --no-pager 2>/dev/null | head -5 || true

        # Check if actually running
        if chroot /host systemctl is-active sysbox-mgr.service >/dev/null 2>&1; then
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

    cp /usr/local/bin/rsync /host/tmp/rsync-static
    cp /usr/local/bin/sysbox-* /host/tmp/
    chmod +x /host/tmp/rsync-static /host/tmp/sysbox-*

    # Create symlinks for dependencies
    chroot /host ln -sf /tmp/rsync-static /usr/bin/rsync 2>/dev/null || true
    chroot /host ln -sf /usr/sbin/modprobe /usr/bin/modprobe 2>/dev/null || true
    chroot /host ln -sf /usr/sbin/iptables /usr/bin/iptables 2>/dev/null || true

    # Handle fusermount/fusermount3 (Alpine has fusermount3, sysbox expects fusermount)
    if ! chroot /host which fusermount >/dev/null 2>&1; then
        if chroot /host which fusermount3 >/dev/null 2>&1; then
            log_info "Creating symlink: fusermount -> fusermount3"
            chroot /host ln -sf /usr/bin/fusermount3 /usr/bin/fusermount
        else
            log_warning "Neither fusermount nor fusermount3 found - FUSE operations may fail"
        fi
    fi

    log_success "Binaries copied and dependencies linked"
}

# Setup /etc configuration (subuid/subgid)
setup_etc_config() {
    log_info "Setting up /etc configuration..."

    # Create subuid/subgid files
    echo "sysbox:200000:65536" >/host/tmp/subuid.tmp
    echo "sysbox:200000:65536" >/host/tmp/subgid.tmp

    # Note: The actual /etc overlay will be handled by systemd service
    log_success "Created subuid/subgid configuration files"
    log_info "These will be applied when the overlay service starts"
}

# Configure Docker runtime
configure_docker() {
    log_info "Configuring Docker runtime..."

    # TODO: Implement proper JSON merging to preserve existing Docker configuration
    # Currently overwrites daemon.json - should merge with existing runtimes/settings

    # Backup existing daemon.json if it exists
    if chroot /host [ -f /etc/docker/daemon.json ]; then
        chroot /host cp /etc/docker/daemon.json /etc/docker/daemon.json.backup
        log_info "Backed up existing Docker daemon.json (will be overwritten)"
    fi

    chroot /host tee /etc/docker/daemon.json >/dev/null <<'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "10"
  },
  "runtimes": {
    "sysbox-runc": {
      "path": "/tmp/sysbox-runc"
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
    chroot /host mkdir -p /run/systemd/system

    # Copy all service files from container to host runtime directory
    cp /usr/local/share/sysbox-etc-overlay.service /host/run/systemd/system/
    cp /usr/local/share/sysbox-mgr.service /host/run/systemd/system/
    cp /usr/local/share/sysbox-fs.service /host/run/systemd/system/

    # Create a setup script for subuid/subgid
    cat >/host/tmp/sysbox-setup.sh <<'EOF'
#!/bin/sh
# Apply subuid/subgid configuration after overlay mount
if [ -f /tmp/subuid.tmp ]; then
    cat /tmp/subuid.tmp > /etc/subuid
    cat /tmp/subgid.tmp > /etc/subgid
    rm -f /tmp/subuid.tmp /tmp/subgid.tmp
fi
EOF
    chmod +x /host/tmp/sysbox-setup.sh

    # Verify files were copied
    if [ ! -f /host/run/systemd/system/sysbox-etc-overlay.service ]; then
        log_error "Failed to copy sysbox-etc-overlay.service to /run/systemd/system/"
        return 1
    fi

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
    chroot /host systemctl daemon-reload

    # Note: We don't enable services as that requires writing to /etc/systemd/system/*.wants/
    # Services in /run are transient and will be lost on reboot anyway
    log_success "Systemd services created (transient until reboot)"
    log_info "Services: sysbox-etc-overlay, sysbox-mgr, sysbox-fs"
    log_info "Services will be started without enabling (read-only /etc)"
}

# Start Sysbox services
start_sysbox() {
    log_info "Starting Sysbox services..."

    # Create data directory
    chroot /host mkdir -p /dstack/persistent/sysbox-data

    # Start services in order: overlay first, then sysbox-mgr, then sysbox-fs
    log_info "Starting /etc overlay service..."
    chroot /host systemctl start sysbox-etc-overlay.service
    sleep 2

    # Apply subuid/subgid configuration
    chroot /host /tmp/sysbox-setup.sh

    log_info "Starting Sysbox manager..."
    chroot /host systemctl start sysbox-mgr.service
    sleep 3

    log_info "Starting Sysbox filesystem..."
    chroot /host systemctl start sysbox-fs.service
    sleep 2

    # Verify services are running
    if chroot /host systemctl is-active sysbox-etc-overlay.service >/dev/null &&
        chroot /host systemctl is-active sysbox-mgr.service >/dev/null &&
        chroot /host systemctl is-active sysbox-fs.service >/dev/null; then
        log_success "All Sysbox services started successfully"
    else
        log_warning "Some services may not have started correctly"
        log_info "Check status with: systemctl status sysbox-etc-overlay sysbox-mgr sysbox-fs"
        log_info "Check logs with: journalctl -u sysbox-etc-overlay -u sysbox-mgr -u sysbox-fs"
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
    echo "  • Sysbox Manager: $(chroot /host systemctl is-active sysbox-mgr.service)"
    echo "  • Sysbox FS:      $(chroot /host systemctl is-active sysbox-fs.service)"
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
    echo "  • Overlay data: /dstack/persistent/sysbox-etc-overlay"
    echo
}

# Main installation flow
main() {
    check_existing
    copy_binaries
    setup_etc_config
    configure_docker
    create_systemd_services
    start_sysbox
    show_status
}

# Run main function
main "$@"

#!/bin/bash

set -e

# SHA256 checksums for known versions
RSYNC_VERSION="3.2.7"
RSYNC_URL="https://download.samba.org/pub/rsync/src/rsync-${RSYNC_VERSION}.tar.gz"
RSYNC_SHA256="4e7d9d3f6ed10878c58c5fb724a67dacf4b6aac7340b13e488fb2dc41346f2bb"

# Sysbox version and commit hash for security
SYSBOX_VERSION="v0.6.7"
SYSBOX_URL="https://github.com/nestybox/sysbox.git"
SYSBOX_COMMIT_HASH="3a69811f54f8f83264ebb36dcaf51708e80b9e84" # Actual commit hash for v0.6.7

log_info() {
    echo "ℹ️  $1"
}

log_success() {
    echo "✅ $1"
}

log_error() {
    echo "❌ $1"
    exit 1
}

verify_rsync() {
    local file="$1"

    log_info "Verifying rsync download..."

    if [ ! -f "$file" ]; then
        log_error "rsync file not found: $file"
    fi

    local actual_sha256=$(sha256sum "$file" | cut -d' ' -f1)

    if [ "$actual_sha256" != "$RSYNC_SHA256" ]; then
        log_error "rsync SHA256 mismatch!"
        echo "Expected: $RSYNC_SHA256"
        echo "Actual:   $actual_sha256"
        return 1
    fi

    log_success "rsync SHA256 verification passed"
}

download_and_verify_rsync() {
    local dest_dir="$1"
    local file="$dest_dir/rsync-${RSYNC_VERSION}.tar.gz"

    log_info "Downloading rsync ${RSYNC_VERSION}..."
    wget -O "$file" "$RSYNC_URL"

    verify_rsync "$file"

    echo "$file"
}

verify_sysbox_source() {
    local sysbox_dir="$1"

    log_info "Verifying Sysbox source..."

    if [ ! -d "$sysbox_dir" ]; then
        log_error "Sysbox source directory not found: $sysbox_dir"
    fi

    if [ ! -f "$sysbox_dir/Makefile" ]; then
        log_error "Sysbox Makefile not found in $sysbox_dir"
    fi

    # Check commit hash for security
    cd "$sysbox_dir"
    local current_hash=$(git rev-parse HEAD)

    if [ "$current_hash" != "$SYSBOX_COMMIT_HASH" ]; then
        log_error "Sysbox commit hash mismatch!"
        echo "Expected: $SYSBOX_COMMIT_HASH"
        echo "Actual:   $current_hash"
        return 1
    fi

    # Also verify the tag
    local current_tag=$(git describe --tags --exact-match HEAD 2>/dev/null || echo "unknown")
    if [ "$current_tag" = "$SYSBOX_VERSION" ]; then
        log_success "Sysbox $SYSBOX_VERSION (commit: ${current_hash:0:8}) verified"
    else
        log_info "Sysbox commit $current_hash verified (tag: $current_tag)"
    fi
}

clone_sysbox() {
    local dest_dir="$1"
    local sysbox_dir="$dest_dir/sysbox"

    log_info "Cloning Sysbox repository with submodules..."

    # Clone the repository
    git clone "$SYSBOX_URL" "$sysbox_dir"

    cd "$sysbox_dir"

    # Checkout specific commit for security
    git checkout "$SYSBOX_COMMIT_HASH"

    # Initialize and update submodules recursively
    git submodule update --init --recursive

    log_info "Sysbox cloned with all submodules"

    verify_sysbox_source "$sysbox_dir"

    echo "$sysbox_dir"
}

# Export functions for use in Dockerfile
export -f log_info log_success log_error verify_rsync download_and_verify_rsync verify_sysbox_source clone_sysbox

# If run directly, execute based on arguments
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "$1" in
    "rsync")
        download_and_verify_rsync "$2"
        ;;
    "sysbox")
        clone_sysbox "$2"
        ;;
    "verify-rsync")
        verify_rsync "$2"
        ;;
    "verify-sysbox")
        verify_sysbox_source "$2"
        ;;
    *)
        echo "Usage: $0 {rsync|sysbox|verify-rsync|verify-sysbox} <path>"
        exit 1
        ;;
    esac
fi

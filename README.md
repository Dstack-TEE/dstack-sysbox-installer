# Sysbox Installer for dstack

A Docker-based installer for [Sysbox](https://github.com/nestybox/sysbox) on read-only dstack systems.

## Features

- 🚀 **Single-command installation** - One Docker run command installs everything
- 🔒 **Source-built** - Builds Sysbox from verified Git source (v0.6.7)
- ✅ **SHA256 verified** - All downloads verified with checksums
- 🔄 **Smart overlay handling** - Preserves existing /etc configurations
- 📋 **Systemd integration** - Installs proper systemd services for Sysbox daemons
- 🔍 **Installation detection** - Checks for existing installations
- 🧪 **Built-in testing** - Verifies installation with basic and Docker-in-Docker tests

## Quick Start

### Build the Installer

```bash
cd installer
chmod +x build.sh
./build.sh sysbox-installer latest
```

### Install Sysbox

**Single command installation:**
```bash
docker run --rm --privileged --pid=host --net=host -v /:/host \
  sysbox-installer:latest
```

That's it! The installer will:
- Check for existing installations
- Build and install Sysbox from source
- Handle /etc overlay mount complexities
- Configure Docker runtime
- Create and start systemd services

## Manual Steps (if needed)

### Interactive Installation

```bash
docker run -it --rm --privileged --pid=host --net=host -v /:/host \
  sysbox-installer:latest bash
```

Then run: `/usr/local/bin/install-sysbox-complete.sh`

### Check Build Information

```bash
docker run --rm sysbox-installer:latest cat /usr/local/share/BUILD_INFO
```

## Usage After Installation

### Run Containers with Sysbox

```bash
# Basic system container
docker run --runtime=sysbox-runc -it ubuntu bash

# Docker-in-Docker
docker run --runtime=sysbox-runc -d --name docker-container docker:dind

# Kubernetes-in-Docker
docker run --runtime=sysbox-runc -d --name k8s-node kindest/node:latest
```

### Manage Sysbox Services

```bash
# Check status
systemctl status sysbox-mgr sysbox-fs

# Restart services
systemctl restart sysbox-mgr sysbox-fs

# View logs
journalctl -u sysbox-mgr -u sysbox-fs
```

## File Structure

```
installer/
├── build.sh                           # Build script
├── README.md                          # This file
├── docker/
│   └── Dockerfile                     # Multi-stage build with source compilation
└── scripts/
    ├── install-sysbox-complete.sh     # Main installation script
    ├── verify-downloads.sh            # SHA256 verification for downloads
    ├── sysbox-mgr.service            # systemd service for sysbox-mgr
    └── sysbox-fs.service             # systemd service for sysbox-fs
```

## Technical Details

### What the Installer Does

1. **Checks existing installation** - Prompts before overwriting
2. **Copies binaries** - Places Sysbox binaries in `/usr/bin` (writable location)
3. **Sets up /etc overlay** - Creates persistent overlay preserving existing configs
4. **Creates symlinks** - Links rsync, modprobe, iptables for Sysbox requirements
5. **Configures Docker** - Adds sysbox-runc runtime to Docker daemon
6. **Creates systemd services** - Installs proper service files with dependencies
7. **Starts services** - Enables and starts Sysbox daemons
8. **Tests installation** - Verifies basic and Docker-in-Docker functionality

### Data Locations

- **Sysbox data**: `/dstack/persistent/sysbox-data`
- **Binaries**: `/usr/bin`

### Security

- All downloads verified with SHA256 checksums
- Sysbox built from official Git repository (recursive clone)
- Uses specific version tags (v0.6.7)
- Proper systemd service isolation

## Troubleshooting

### Check Service Status
```bash
systemctl status sysbox-mgr sysbox-fs
journalctl -u sysbox-mgr -u sysbox-fs
```

### Verify Docker Runtime
```bash
docker info | grep -A5 Runtimes
```

### Test Basic Functionality
```bash
docker run --runtime=sysbox-runc --rm alpine echo "Test successful"
```

### Clean Installation
```bash
systemctl stop sysbox-mgr sysbox-fs
systemctl disable sysbox-mgr sysbox-fs
rm -f /etc/systemd/system/sysbox-*.service
umount /etc  # If overlay mounted
rm -rf /dstack/persistent/sysbox-*
```

## Requirements

- Docker installed and running
- Privileged container execution
- dstack system with ZFS persistent storage
- systemd for service management

## Support

For issues with the installer, check:
1. Docker daemon is running
2. Container has privileged access
3. `/dstack/persistent/` is available and writable
4. systemd is available on the host

For Sysbox issues, see: https://github.com/nestybox/sysbox

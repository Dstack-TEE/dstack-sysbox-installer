# Sysbox Installer for dstack

A Docker-based installer for [Sysbox](https://github.com/nestybox/sysbox) on read-only dstack systems.

## Quick Start

### Build the Installer

```bash
cd installer
chmod +x build.sh
./build.sh sysbox-installer latest
```

### Install Sysbox

**Single command installation in a CVM:**
```bash
docker run --rm --privileged --pid=host --net=host -v /:/host \
  sysbox-installer:latest
```

That's it! The installer will:
- Check for existing installations
- Build and install Sysbox from source
- Handle /etc volatile overlay mount preserving configs
- Configure Docker runtime using Sysbox's official script
- Create transient systemd services and start daemons

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

1. **Checks existing installation** - Detects and reports existing Sysbox installations
2. **Copies binaries** - Places Sysbox binaries in `/usr/bin` (writable location)
3. **Sets up /etc overlay** - Creates volatile overlay preserving existing configs (WireGuard, Docker)
4. **Creates symlinks** - Links fusermount, modprobe, iptables for Sysbox requirements
5. **Configures Docker** - Uses Sysbox's official docker-cfg script to properly merge runtime configuration
6. **Creates systemd services** - Installs transient service files in `/run/systemd/system`
7. **Starts services** - Starts Sysbox manager and filesystem daemons

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
rm -f /run/systemd/system/sysbox-*.service
systemctl daemon-reload
umount /etc  # If volatile overlay mounted
rm -rf /dstack/persistent/sysbox-*
```

## Requirements

- Docker installed and running
- Privileged container execution
- dstack system with ZFS persistent storage
- systemd for service management

## Release and Verification

### Creating a Release

Releases are automated via GitHub Actions with sigstore attestation:

1. Tag a new version:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

2. The workflow will automatically:
   - Build the Docker image
   - Push to Docker Hub
   - Generate sigstore attestation
   - Create a GitHub release

### Verifying Image Attestation

All released images are signed with sigstore for supply chain security:

```bash
# Install cosign
curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign

# Verify the image (replace VERSION and DIGEST)
cosign verify-attestation \
  --type https://slsa.dev/provenance/v1 \
  --certificate-identity-regexp "^https://github.com/YOUR_ORG/dstack-sysbox-installer/.github/workflows/release.yml@refs/tags/vVERSION$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/YOUR_ORG/dstack-sysbox-installer@sha256:DIGEST
```

You can also verify on [Sigstore Search](https://search.sigstore.dev/).

## Support

For issues with the installer, check:
1. Docker daemon is running
2. Container has privileged access
3. `/dstack/persistent/` is available and writable
4. systemd is available on the host

For Sysbox issues, see: https://github.com/nestybox/sysbox

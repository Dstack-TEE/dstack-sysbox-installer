#!/bin/bash

set -e

IMAGE_NAME="${1:-kvin/dstack-sysbox-installer}"
IMAGE_TAG="${2:-latest}"

echo "=========================================="
echo "🔨 Building Sysbox Installer"
echo "=========================================="

# Change to installer directory
cd "$(dirname "$0")"

echo "📁 Build context: $(pwd)"
echo "🏷️  Image: ${IMAGE_NAME}:${IMAGE_TAG}"

# Verify required files exist
echo "✅ Checking required files..."
for file in scripts/install-sysbox-complete.sh scripts/verify-downloads.sh scripts/sysbox-mgr.service scripts/sysbox-fs.service docker/Dockerfile; do
    if [ ! -f "$file" ]; then
        echo "❌ Missing required file: $file"
        exit 1
    fi
done

# Build the image
echo "🚀 Building Docker image..."
docker build -f docker/Dockerfile -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo
echo "=========================================="
echo "✅ Build Complete!"
echo "=========================================="
echo
echo "📦 Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo
echo "🚀 Usage:"
echo
echo "Single-command installation:"
echo "  docker run --rm --privileged --pid=host --net=host -v /:/host \\"
echo "    ${IMAGE_NAME}:${IMAGE_TAG}"
echo
echo "Interactive installation:"
echo "  docker run -it --rm --privileged --pid=host --net=host -v /:/host \\"
echo "    ${IMAGE_NAME}:${IMAGE_TAG} bash"
echo
echo "Check build info:"
echo "  docker run --rm ${IMAGE_NAME}:${IMAGE_TAG} cat /usr/local/share/BUILD_INFO"
echo
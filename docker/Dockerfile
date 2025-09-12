# Multi-stage build for Sysbox installer
# Stage 1: Build dependencies (rsync and Sysbox)
FROM ubuntu:24.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    wget \
    git \
    build-essential \
    autoconf \
    automake \
    libbtrfs-dev \
    libseccomp-dev \
    libseccomp2 \
    pkg-config \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Install Go for Sysbox build
RUN wget -O- https://golang.org/dl/go1.21.5.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"

# Install Go protobuf plugins
RUN go install github.com/golang/protobuf/protoc-gen-go@latest
ENV PATH="${PATH}:/root/go/bin"

WORKDIR /build

# Copy verification script
COPY scripts/verify-downloads.sh /usr/local/bin/verify-downloads.sh
RUN chmod +x /usr/local/bin/verify-downloads.sh

# Download and verify rsync
RUN /usr/local/bin/verify-downloads.sh rsync /build && \
    cd /build && \
    tar xzf rsync-3.2.7.tar.gz && \
    cd rsync-3.2.7 && \
    CFLAGS="-static" ./configure \
        --disable-openssl \
        --disable-xxhash \
        --disable-zstd \
        --disable-lz4 && \
    make LDFLAGS="-static" -j$(nproc) && \
    strip rsync

# Clone and build Sysbox from source
RUN /usr/local/bin/verify-downloads.sh sysbox /build && \
    cd /build/sysbox && \
    make sysbox-static-local && \
    make install DESTDIR=/build/sysbox-install

# Stage 2: Final runtime image
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    docker \
    iptables \
    util-linux \
    coreutils \
    findutils

# Copy built binaries from builder stage
COPY --from=builder /build/rsync-3.2.7/rsync /usr/local/bin/rsync
COPY --from=builder /build/sysbox-install/sysbox-runc /usr/local/bin/sysbox-runc
COPY --from=builder /build/sysbox-install/sysbox-mgr /usr/local/bin/sysbox-mgr
COPY --from=builder /build/sysbox-install/sysbox-fs /usr/local/bin/sysbox-fs
COPY --from=builder /build/sysbox/scr/docker-cfg /usr/local/bin/sysbox-docker-cfg

# Copy scripts and service files
COPY scripts/install-sysbox-complete.sh /usr/local/bin/install-sysbox-complete.sh
COPY scripts/verify-downloads.sh /usr/local/bin/verify-downloads.sh
COPY scripts/sysbox-mgr.service /usr/local/share/sysbox-mgr.service
COPY scripts/sysbox-fs.service /usr/local/share/sysbox-fs.service

# Make everything executable
RUN chmod +x /usr/local/bin/*

# Create build info
RUN echo "Sysbox Installer Image" > /usr/local/share/BUILD_INFO && \
    echo "Built: $(date)" >> /usr/local/share/BUILD_INFO && \
    echo "Sysbox: $(/usr/local/bin/sysbox-mgr --version | head -1)" >> /usr/local/share/BUILD_INFO && \
    echo "rsync: $(/usr/local/bin/rsync --version | head -1)" >> /usr/local/share/BUILD_INFO

WORKDIR /workspace

# Default command runs the complete installer
CMD ["/usr/local/bin/install-sysbox-complete.sh"]
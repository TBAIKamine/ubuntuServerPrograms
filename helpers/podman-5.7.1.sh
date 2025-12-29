#!/bin/bash
set -e

# Create temp directory for build
BUILD_DIR=$(mktemp -d)
trap "rm -rf $BUILD_DIR" EXIT

cd "$BUILD_DIR"

# 1. Install Build Dependencies
apt update
apt install -y \
  btrfs-progs \
  git \
  golang-go \
  go-md2man \
  iptables \
  libassuan-dev \
  libbtrfs-dev \
  libc6-dev \
  libdevmapper-dev \
  libglib2.0-dev \
  libgpgme-dev \
  libgpg-error-dev \
  libprotobuf-dev \
  libprotobuf-c-dev \
  libseccomp-dev \
  libselinux1-dev \
  libsystemd-dev \
  make \
  pkg-config \
  uidmap

# 2. Install latest Go (Standard practice for Podman 5+)
# Ubuntu 24.04 repos may have an older Go version.
# This step ensures we use the version required by Podman's go.mod
export GOPATH=$HOME/go
export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin

# 3. Clone and Build Conmon (Required runtime dependency)
git clone https://github.com/containers/conmon
cd conmon
make
make install
cd ..

# 4. Clone and Build Podman (Latest Stable Tag)
git clone https://github.com/containers/podman
cd podman

# Fetch tags and checkout the latest stable version
LATEST_TAG=$(git describe --tags `git rev-list --tags --max-count=1`)
git checkout $LATEST_TAG

# Build and Install
make BUILDTAGS="selinux seccomp"
make install PREFIX=/usr

# 5. Add Default Configuration Files
mkdir -p /etc/containers
curl -L -o /etc/containers/registries.conf https://raw.githubusercontent.com/containers/image/main/registries.conf
curl -L -o /etc/containers/policy.json https://raw.githubusercontent.com/containers/image/main/default-policy.json

# 6. Configure runtime paths explicitly
mkdir -p /usr/share/containers
cat > /etc/containers/containers.conf <<'CONF'
[engine]
runtime = "crun"
conmon_path = [
  "/usr/local/bin/conmon",
  "/usr/bin/conmon"
]

[engine.runtimes]
crun = [
  "/usr/bin/crun",
  "/usr/local/bin/crun"
]
CONF

echo "Podman build complete. Version installed:"
podman --version
echo "Runtime (crun) version:"
crun --version
echo "Conmon version:"
conmon --version

# Cleanup happens automatically via trap
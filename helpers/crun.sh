#!/bin/bash
set -e

# Remove apt version of crun
apt purge -y crun || true
rm /etc/containers/policy.json 2>/dev/null || true

# Create temp directory for build
BUILD_DIR=$(mktemp -d)
trap "rm -rf $BUILD_DIR" EXIT

cd "$BUILD_DIR"

# Install build dependencies
apt-get install -y make git gcc build-essential pkgconf libtool \
   libsystemd-dev libprotobuf-c-dev libcap-dev libseccomp-dev libyajl-dev \
   go-md2man autoconf python3 automake

# Clone and build latest crun
git clone https://github.com/containers/crun.git
cd crun
./autogen.sh
./configure
make

# Install to /usr/bin (matches podman PREFIX=/usr)
cp crun /usr/bin/
chmod +x /usr/bin/crun

echo "crun installed. Version:"
/usr/bin/crun --version

# Cleanup happens automatically via trap
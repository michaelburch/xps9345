#!/bin/bash

export INSTALL_MOD_STRIP=1
export LLVM=1

if ! sudo -v; then
  echo "Unable to get sudo privileges."
  exit 1
fi

# Sudo loop.
# Keep-alive: update existing `sudo` timestamp until script finishes
# Runs in the background
while true; do
  sleep 60
  sudo -n -v
  kill -0 "$$" || exit
done 2>/dev/null &

# Compile.
make -j`nproc` && \
    # Install.
    sudo -E make INSTALL_DTBS_PATH=/usr/lib/modules/$(make -s kernelrelease)/dtb dtbs_install -j`nproc` && \
    sudo -E make modules_install -j`nproc` && \
    sudo -E make install -j`nproc`

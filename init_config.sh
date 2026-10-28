#!/bin/bash

set -euo pipefail

export INSTALL_MOD_STRIP=1
export LLVM=1

if [[ -e .config ]]; then
  echo 'Refusing to overwrite existing .config; preserve incremental build state.' >&2
  exit 1
fi

cp arch/arm64/configs/xps9345.config .config
make LOCALVERSION= olddefconfig

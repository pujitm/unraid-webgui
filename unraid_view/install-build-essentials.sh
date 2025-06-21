#!/bin/bash
# install-build-essentials.sh
# Installs only the *missing* build-toolchain bits without downgrading anything.

set -euo pipefail

MIRROR="https://mirrors.slackware.com/slackware/slackware64-current/slackware64"
PKGS=(
  a/aaa_glibc-solibs-2.41-x86_64-2.txz          # runtime glibc slice
  n/openssl-3.5.0-x86_64-1.txz
  # a/openssl-solibs-3.5.0-x86_64-1.txz           # matches your openssl 3.5.0


  l/libmpc-1.3.1-x86_64-1.txz                   # math libs for GCC
  l/isl-0.27-x86_64-1.txz
  l/glibc-2.41-x86_64-2.txz
  l/gc-8.2.8-x86_64-1.txz

  d/kernel-headers-6.12.34-x86-1.txz
  d/guile-3.0.10-x86_64-1.txz
  d/binutils-2.44-x86_64-1.txz                  # assembler & linker
  d/gcc-15.1.0-x86_64-1.txz                     # core compiler
  d/gcc-g++-15.1.0-x86_64-1.txz                 # C++ front-end
  d/make-4.4.1-x86_64-1.txz
  d/pkgconf-2.5.0-x86_64-1.txz
  d/gdb-16.3-x86_64-1.txz
  d/autoconf-2.72-noarch-1.txz
  d/automake-1.18-noarch-1.txz
  d/libtool-2.5.4-x86_64-3.txz
  d/m4-1.4.20-x86_64-1.txz
  d/cmake-4.0.3-x86_64-1.txz
  d/bison-3.8.2-x86_64-1.txz
  d/ccache-4.11.3-x86_64-1.txz                  # optional speed-up
)

need_install() {
  local p=$1
  local base=${p##*/}
  local tag=${base%.txz}           # strip .txz
  local short=${tag%%-[0-9]*}      # e.g. gcc
  # already installed?
  if ls /var/log/packages/"$short"-* &>/dev/null; then
    echo "skip"
  else
    echo "install"
  fi
}

for pkg in "${PKGS[@]}"; do
  action=$(need_install "$pkg")
  if [[ $action == install ]]; then
    wget "$MIRROR/$pkg"
  else
    echo "==  already present: $pkg"
  fi
done

installpkg ./*.txz

echo "Done."
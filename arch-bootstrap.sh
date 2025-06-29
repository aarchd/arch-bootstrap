#!/bin/bash
#
# arch-bootstrap: Bootstrap a base Arch Linux system using any GNU distribution.
#
# Dependencies: bash >= 4, coreutils, curl, sed, gawk, tar, gzip, chroot, xz, zstd.
# Project: https://github.com/tokland/arch-bootstrap
#
# Install:
#
#   # install -m 755 arch-bootstrap.sh /usr/local/bin/arch-bootstrap
#
# Usage:
#
#   # arch-bootstrap destination
#   # arch-bootstrap -a x86_64 -r ftp://ftp.archlinux.org destination-64
#
# And then you can chroot to the destination directory (user: root, password: 3355):
#
#   # chroot destination

set -e -u -o pipefail

# Define colors for colorful output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
RESET="\033[0m"

# Packages needed by pacman (see get-pacman-dependencies.sh)
PACMAN_PACKAGES=(
  acl archlinux-keyring attr brotli bzip2 curl expat glibc gpgme libarchive
  libassuan libgpg-error libnghttp2 libnghttp3 libssh2 lzo openssl pacman pacman-mirrorlist xz zlib
  krb5 e2fsprogs keyutils libidn2 libunistring gcc-libs lz4 libpsl icu libunistring zstd libxml2
)
BASIC_PACKAGES=(${PACMAN_PACKAGES[*]} filesystem base)
EXTRA_PACKAGES=(coreutils bash grep gawk file tar gzip systemd sed archlinuxarm-keyring)
DEFAULT_REPO_URL="http://mirrors.kernel.org/archlinux"
DEFAULT_ARM_REPO_URL="http://mirror.archlinuxarm.org"
DEFAULT_X86_REPO_URL="http://mirror.archlinux32.org"

stderr() { 
  echo -e "${RED}$@${RESET}" >&2
}

debug() {
  echo -e "${MAGENTA}--- $@${RESET}"
}

info() {
  echo -e "${CYAN}$@${RESET}"
}

success() {
  echo -e "${GREEN}$@${RESET}"
}

warn() {
  echo -e "${YELLOW}$@${RESET}"
}

error() {
  echo -e "${RED}$@${RESET}"
}

extract_href() {
  sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\)".*$/\1/p'
}

fetch() {
  curl -L -# -s "$@"
}

fetch_file() {
  local FILEPATH=$1
  shift
  if [[ -e "$FILEPATH" ]]; then
    curl -L -z "$FILEPATH" -# -o "$FILEPATH" "$@"
  else
    curl -L -# -o "$FILEPATH" "$@"
  fi
}


uncompress() {
  local FILEPATH=$1 DEST=$2
  
  case "$FILEPATH" in
    *.gz) 
      tar xzf "$FILEPATH" -C "$DEST";;
    *.xz) 
      xz -dc "$FILEPATH" | tar x -C "$DEST";;
    *.zst)
      zstd -dc "$FILEPATH" | tar x -C "$DEST";;
    *)
      error "Error: unknown package format: $FILEPATH"
      return 1;;
  esac
}  

###

get_default_repo() {
  local ARCH=$1
  if [[ "$ARCH" == arm* || "$ARCH" == aarch64 ]]; then
    echo $DEFAULT_ARM_REPO_URL
  elif [[ "$ARCH" == i*86 || "$ARCH" == pentium4 ]]; then
    echo $DEFAULT_X86_REPO_URL
  else
    echo $DEFAULT_REPO_URL
  fi
}

get_core_repo_url() {
  local REPO_URL=$1 ARCH=$2
  if [[ "$ARCH" == arm* || "$ARCH" == aarch64 || "$ARCH" == i*86 || "$ARCH" == pentium4 ]]; then
    echo "${REPO_URL%/}/$ARCH/core"
  else
    echo "${REPO_URL%/}/core/os/$ARCH"
  fi
}

get_template_repo_url() {
  local REPO_URL=$1 ARCH=$2
  if [[ "$ARCH" == arm* || "$ARCH" == aarch64 || "$ARCH" == i*86 || "$ARCH" == pentium4 ]]; then
    echo "${REPO_URL%/}/$ARCH/\$repo"
  else
    echo "${REPO_URL%/}/\$repo/os/$ARCH"
  fi
}

configure_pacman() {
  local DEST=$1 ARCH=$2
  debug "Configuring DNS and pacman"
  cp "/etc/resolv.conf" "$DEST/etc/resolv.conf"
  SERVER=$(get_template_repo_url "$REPO_URL" "$ARCH")
  echo "Server = $SERVER" > "$DEST/etc/pacman.d/mirrorlist"
}

configure_pacman2() {
  local DEST=$1
  find "$DEST/etc" -type f -name '*.pacnew' | while read -r pacnew; do
    orig="${pacnew%.pacnew}"
    echo "Replacing $orig with $pacnew"
    mv -f "$pacnew" "$orig"
  done
  sed -i "s/^[[:space:]]*\(CheckSpace\)/# \1/" "$DEST/etc/pacman.conf"
}

configure_minimal_system() {
  local DEST=$1
  
  mkdir -p "$DEST/dev"
  sed -ie 's/^root:.*$/root:$1$GT9AUpJe$uTUJeUtwcBVzlA.aYn5yK.:14657::::::/' "$DEST/etc/shadow"
  touch "$DEST/etc/group"

  rm -f "$DEST/etc/mtab"
  echo "rootfs / rootfs rw 0 0" > "$DEST/etc/mtab"

  sed -i 's/^DownloadUser/#DownloadUser/' "$DEST/etc/pacman.conf"
  sed -i "s/^[[:space:]]*\(CheckSpace\)/# \1/" "$DEST/etc/pacman.conf"
  sed -i "s/^[[:space:]]*SigLevel[[:space:]]*=.*$/SigLevel = Never/" "$DEST/etc/pacman.conf"
  sed -i "s/PKGEXT='.pkg.tar.xz'/PKGEXT='.pkg.tar.zst'/" "$DEST/etc/makepkg.conf"
}

fetch_packages_list() {
  local REPO=$1 
  
  debug "Fetching packages list from: $REPO/"
  fetch "$REPO/" | extract_href | awk -F"/" '{print $NF}' | sort -rn ||
    { error "Cannot fetch packages list from: $REPO"; return 1; }
}

install_pacman_packages() {
  local BASIC_PACKAGES=$1 DEST=$2 LIST=$3 DOWNLOAD_DIR=$4
  debug "Installing pacman packages and dependencies: $BASIC_PACKAGES"
  
  for PACKAGE in $BASIC_PACKAGES; do
    local FILE=$(echo "$LIST" | grep -m1 "^$PACKAGE-[[:digit:]].*\(\.gz\|\.xz\|\.zst\)$")
    test "$FILE" || { error "Cannot find package: $PACKAGE"; return 1; }
    local FILEPATH="$DOWNLOAD_DIR/$FILE"
    
    debug "Downloading package: $REPO/$FILE"
    fetch_file "$FILEPATH" "$REPO/$FILE"
    debug "Uncompressing package: $FILEPATH"
    uncompress "$FILEPATH" "$DEST"
  done
}

configure_static_qemu() {
  local ARCH=$1 DEST=$2
  [[ "$ARCH" == arm* ]] && ARCH=arm
  QEMU_STATIC_BIN=$(which qemu-$ARCH-static || echo )
  [[ -e "$QEMU_STATIC_BIN" ]] ||\
    { debug "No static qemu for $ARCH, ignoring"; return 0; }
  cp "$QEMU_STATIC_BIN" "$DEST/usr/bin"
}

install_packages() {
  local ARCH=$1 DEST=$2 PACKAGES=$3
  debug "Fixing permissions"
  debug "Installing packages: $PACKAGES"
  LC_ALL=C chroot "$DEST" /usr/bin/pacman \
    --noconfirm --arch $ARCH -Sy --overwrite \* $PACKAGES
}

show_usage() {
  stderr "Usage: $(basename "$0") [-q] [-a i486|i686|pentium4|x86_64|arm|aarch64] [-r REPO_URL] [-d DOWNLOAD_DIR] DESTDIR"
}

main() {
  # Process arguments and options
  test $# -eq 0 && set -- "-h"
  local ARCH=
  local REPO_URL=
  local USE_QEMU=
  local DOWNLOAD_DIR=
  local PRESERVE_DOWNLOAD_DIR=
  
  while getopts "qa:r:d:h" ARG; do
    case "$ARG" in
      a) ARCH=$OPTARG;;
      r) REPO_URL=$OPTARG;;
      q) USE_QEMU=true;;
      d) DOWNLOAD_DIR=$OPTARG
         PRESERVE_DOWNLOAD_DIR=true;;
      *) show_usage; return 1;;
    esac
  done
  shift $(($OPTIND-1))
  test $# -eq 1 || { show_usage; return 1; }
  
  [[ -z "$ARCH" ]] && ARCH=$(uname -m)
  [[ -z "$REPO_URL" ]] &&REPO_URL=$(get_default_repo "$ARCH")
  
  local DEST=$1
  local REPO=$(get_core_repo_url "$REPO_URL" "$ARCH")
  [[ -z "$DOWNLOAD_DIR" ]] && DOWNLOAD_DIR=$(mktemp -d)
  mkdir -p "$DOWNLOAD_DIR"
  [[ -z "$PRESERVE_DOWNLOAD_DIR" ]] && trap "rm -rf '$DOWNLOAD_DIR'" KILL TERM EXIT
  debug "Destination directory: $DEST"
  debug "Core repository: $REPO"
  debug "Temporary directory: $DOWNLOAD_DIR"
  
  # Fetch packages, install system and do a minimal configuration
  mkdir -p "$DEST"
  local LIST=$(fetch_packages_list $REPO)
  install_pacman_packages "${BASIC_PACKAGES[*]}" "$DEST" "$LIST" "$DOWNLOAD_DIR"
  configure_pacman "$DEST" "$ARCH"
  configure_minimal_system "$DEST"
  [[ -n "$USE_QEMU" ]] && configure_static_qemu "$ARCH" "$DEST"
  install_packages "$ARCH" "$DEST" "${BASIC_PACKAGES[*]} ${EXTRA_PACKAGES[*]}"
  configure_pacman2 "$DEST"
  [[ -z "$PRESERVE_DOWNLOAD_DIR" ]] && rm -rf "$DOWNLOAD_DIR"
  
  success 
  success "Done!"
  success 
}

main "$@"


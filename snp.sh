#!/bin/bash
#  SPDX-License-Identifier: MIT
#
#  Copyright (C) 2023 Advanced Micro Devices, Inc.  
#

#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#

###   SNP Utility Script

# AMDSEV - snp-latest (UPM):
# 1. Enable host SNP options in BIOS
# 2. ./snp.sh setup-host
# 3. sudo reboot
# 4. ./snp.sh launch-guest
# 5. ./snp.sh attest-guest
# 6. ssh -p 10022 -i snp-guest-key amd@localhost

# AMDSEV - sev-snp-devel (non-UPM):
# 1. Enable host SNP options in BIOS
# 2. ./snp.sh --non-upm setup-host
# 3. sudo reboot
# 4. ./snp.sh --non-upm launch-guest
# 5. ./snp.sh attest-guest
# 6. ssh -p 10022 -i snp-guest-key amd@localhost

# BYOI Example:
# Image must have the GUEST_USER already added.
# Image must have the ssh key already injected for the specified user.
# Ensure enough space exists on the guest for the kernel installation.
#
# export IMAGE="guest.img"
# export GUEST_USER="user"
# export GUEST_SSH_KEY_PATH="guest-key"
# ./snp.sh launch-guest

# Enable host SNP options in CRB BIOS:
# CBS -> CPU Common ->
#        SEV-ES ASID space limit -> 100
#        SNP Memory Coverage -> Enabled 
#        SMEE -> Enabled
#     -> NBIO common ->
#             SEV-SNP -> Enabled

# Tested on the following OS distributions:
# Ubuntu 20.04, 22.04

# Image formats supported:
# qcow2

# WARNING:
# This script installs developer packages on the system it is run on.
# Beware and check 'install_dependencies' if there are any admin concerns.

# WARNING:
# This script sets the default grub entry to the SNP kernel version that is 
# built for this host in this script. Modifying the system grub can cause 
# booting issues.

#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#*#

set -eE
#set -o nounset
set -o pipefail

trap cleanup EXIT

source ./qemu-conf.sh

# Working directory setup
# WORKING_DIR="${WORKING_DIR:-$HOME/snp}"
WORKING_DIR="$PWD/snp"
SETUP_WORKING_DIR="${SETUP_WORKING_DIR:-${WORKING_DIR}/setup}"
LAUNCH_WORKING_DIR="${LAUNCH_WORKING_DIR:-${WORKING_DIR}/launch}"
ATTESTATION_WORKING_DIR="${ATTESTATION_WORKING_DIR:-${WORKING_DIR}/attest}"

# Export environment variables
COMMAND="help"
UPM=true
SKIP_IMAGE_CREATE=false
HOST_SSH_PORT="${HOST_SSH_PORT:-10022}"
GUEST_NAME="${GUEST_NAME:-snp-guest}"
GUEST_SIZE_GB="${GUEST_SIZE_GB:-20}"
GUEST_USER="${GUEST_USER:-amd}"
GUEST_PASS="${GUEST_PASS:-amd}"
GUEST_SSH_KEY_PATH="${GUEST_SSH_KEY_PATH:-${LAUNCH_WORKING_DIR}/${GUEST_NAME}-key}"
GUEST_ROOT_LABEL="${GUEST_ROOT_LABEL:-cloudimg-rootfs}"
GUEST_KERNEL_APPEND="root=LABEL=${GUEST_ROOT_LABEL} ro console=ttyS0"
QEMU_CMDLINE_FILE="${QEMU_CMDLINE:-${LAUNCH_WORKING_DIR}/qemu.cmdline}"
IMAGE="${IMAGE:-${LAUNCH_WORKING_DIR}/${GUEST_NAME}.img}"
GENERATED_INITRD_BIN="${SETUP_WORKING_DIR}/initrd.img"

# URLs and repos
AMDSEV_URL="https://github.com/ryansavino/AMDSEV.git"
AMDSEV_DEFAULT_BRANCH="snp-latest-fixes"
AMDSEV_NON_UPM_BRANCH="snp-non-upm"
SNPGUEST_URL="https://github.com/virtee/snpguest.git"
SNPGUEST_BRANCH="tags/v0.2.2"
NASM_SOURCE_TAR_URL="https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/nasm-2.16.01.tar.gz"
CLOUD_INIT_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
DRACUT_TARBALL_URL="https://github.com/dracutdevs/dracut/archive/refs/tags/059.tar.gz"



###############################################################################

# Functions

usage() {
  >&2 echo "Usage: $0 [OPTIONS] [COMMAND]"
  >&2 echo "  where COMMAND must be one of the following:"
  >&2 echo "    setup-host            Build required SNP components and set up host"
  >&2 echo "    launch-guest          Launch a SNP guest"
  >&2 echo "    build-guest           Setup a SNP guest"
  >&2 echo "    attest-guest          Use virtee/snpguest and sev-snp-measure to attest a SNP guest"
  >&2 echo "    stop-guests           Stop all SNP guests started by this script"
  >&2 echo "  where OPTIONS are:"
  >&2 echo "    -n|--non-upm          Build AMDSEV non UPM kernel (sev-snp-devel)"
  >&2 echo "    -i|--image            Path to existing image file"
  >&2 echo "    -h|--help             Usage information"

  return 1
}

cleanup() {
  exit_code=$?
  set +eE; set +o nounset +o pipefail

  # popd all the way up
  pushd -0 >/dev/null 2>&1
  dirs -c >/dev/null 2>&1

  if [ ${exit_code} -ne 0 ]; then
    case "${COMMAND}" in
      setup-host)
        cat ${SETUP_WORKING_DIR}/*.log 2>/dev/null
      ;;

      launch-guest)
        #cat ${LAUNCH_WORKING_DIR}/*.log 2>/dev/null
        cat ${LAUNCH_WORKING_DIR}/qemu-trace.log 2>/dev/null
        ;;
      
      build_guest)
        cat ${LAUNCH_WORKING_DIR}/qemu-trace.log 2>/dev/null
        ;;

      attest-guest)
        cat ${ATTESTATION_WORKING_DIR}/*.log 2>/dev/null
        ;;

      stop-guests)
        ;;

      *)
        >&2 echo -e "Unknown ERROR encountered"
      ;;
    esac
  fi
  return $exit_code
}

verify_snp_host() {
  if ! sudo dmesg | grep -i "SEV-SNP supported" 2>&1 >/dev/null; then
    echo -e "SEV-SNP not enabled on the host. Please follow these steps to enable:\n\
    $(echo "${AMDSEV_URL}" | sed 's|\.git$||g')/tree/${AMDSEV_DEFAULT_BRANCH}#prepare-host"
    return 1
  fi
}

install_nasm_from_source() {
  local nasm_dir_name=$(echo "${NASM_SOURCE_TAR_URL}" | sed "s|.*/\(.*\)|\1|g" | sed "s|.tar.gz||g")
  local nasm_dir="${WORKING_DIR}/${nasm_dir_name}"
  
  if [ -d "${nasm_dir}" ]; then
    echo -e "nasm directory detected, skipping the build and install for nasm"
    return 0
  fi

  # Remove package manager nasm
  sudo apt purge nasm
  
  pushd "${WORKING_DIR}" >/dev/null

  # Install from source
  wget ${NASM_SOURCE_TAR_URL} -O "${nasm_dir_name}.tar.gz"
  tar xzvf "${nasm_dir_name}.tar.gz"
  cd "${nasm_dir}"
  ./configure
  make
  sudo make install

  popd >/dev/null
}

install_dependencies() {
  local dependencies_installed_file="${WORKING_DIR}/dependencies_already_installed"
  source "${HOME}/.cargo/env" 2>/dev/null || true

  if [ -f "${dependencies_installed_file}" ]; then
    echo -e "Dependencies previously installed"
    return 0
  fi

  sudo apt update

  # Build dependencies
  sudo apt install -y build-essential git

  # qemu dependencies
  sudo apt install -y ninja-build pkg-config
  sudo apt install -y libglib2.0-dev
  sudo apt install -y libpixman-1-dev
  sudo apt install -y libslirp-dev
  
  # ovmf dependencies
  sudo apt install -y python-is-python3 uuid-dev iasl
  #sudo apt install -y nasm
  install_nasm_from_source

  # kernel dependencies
  sudo apt install -y bc rsync
  sudo apt install -y flex bison libncurses-dev libssl-dev libelf-dev dwarves zstd debhelper

  # dracut dependencies
  # dracut-core in native distro package manager too old with many issues. It is now
  # downloaded via source tarball URL in the environment variable above.
  # The asciidoc package is huge. It is commented because it is only needed for lsinitrd, and
  # the dracut build commands avoid the lsinitrd build.
  # The dracut initrd build is currently not working. Devices are failing to mount using the
  # dracut built initrd. This dependency is removed for now due to this reason. For now,
  # initrd is installed with the kernel debian package on the guest, and then scp-ed back to
  # the host for direct-boot use.
  #sudo apt install -y pkg-config libkmod-dev
  ##sudo apt install -y asciidoc
  ##sudo apt install -y dracut-core

  # cloud-utils dependency
  sudo apt install -y cloud-image-utils

  # Virtualization tools for resizing image
  # virt-resize currently does not work with cloud-init images. It changes the partition 
  # names and grub gets messed up. This dependency is removed for now due to this reason.
  #sudo apt install -y libguestfs-tools
  sudo apt install -y qemu-utils

  # sev-snp-measure
  sudo apt install -y python3-pip
  # pip issue on 20.04 - some openssl bug
  #sudo rm -f "/usr/lib/python3/dist-packages/OpenSSL/crypto.py"
  pip install sev-snp-measure

  # Rust is required to build snpguest
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -sSf | sh -s -- -y
  source "${HOME}/.cargo/env" 2>/dev/null

  echo "true" > "${dependencies_installed_file}"
}

set_grub_default_snp() {
  # Get the path to host kernel and the version for setting grub default
  local host_kernel=$(echo $(realpath "${SETUP_WORKING_DIR}/AMDSEV/linux/host/debian/linux-image/boot/vmlinuz*"))
  local host_kernel_version=$(echo "${host_kernel}" | sed "s|.*/boot/vmlinuz-\(.*\)|\1|g")

  if cat /etc/default/grub | grep "${host_kernel_version}" | grep -v "^#" 2>&1 >/dev/null; then
    echo -e "Default grub already has SNP [${host_kernel_version}] set"
    return 0
  fi

  # Retrieve snp menuitem name from grub.cfg
  local snp_menuitem_name=$(cat /boot/grub/grub.cfg \
    | grep "menuentry.*${host_kernel_version}" \
    | grep -v "(recovery mode)" \
    | grep -o -P "(?<=').*" \
    | grep -o -P "^[^']*")

  # Create default grub backup
  sudo cp /etc/default/grub /etc/default/grub_bkup
  
  # Replace grub default with snp menuitem name
  sudo sed -i -e "s|^\(GRUB_DEFAULT=\).*$|\1\"Advanced options for Ubuntu>${snp_menuitem_name}\"|g" "/etc/default/grub"
  
  sudo update-grub
}

generate_guest_ssh_keypair() {
  if [[ -f "${GUEST_SSH_KEY_PATH}" \
    && -f "${GUEST_SSH_KEY_PATH}.pub" ]]; then
    echo -e "Guest SSH key pair already generated"
    return 0
  fi

  # Create ssh key to access vm
  ssh-keygen -q -t ed25519 -N '' -f "${GUEST_SSH_KEY_PATH}" <<<y
}

cloud_init_create_data() {
  if [[ -f "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-metadata.yaml" && \
    -f "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-user-data.yaml"  && \
    -f "${IMAGE}" ]]; then
    echo -e "cloud-init data already generated"
    return 0
  fi

  local pub_key=$(cat "${GUEST_SSH_KEY_PATH}.pub")

# Seed image metadata
cat > "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-metadata.yaml" <<EOF
instance-id: "${GUEST_NAME}"
local-hostname: "${GUEST_NAME}"
EOF

# Seed image user data
cat > "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-user-data.yaml" <<EOF
#cloud-config
chpasswd:
  expire: false
ssh_pwauth: true
users:
  - default
  - name: ${GUEST_USER}
    plain_text_passwd: ${GUEST_PASS}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${pub_key}
EOF

  # Create the seed image with metadata and user data
  cloud-localds "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-seed.img" \
    "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-user-data.yaml" \
    "${LAUNCH_WORKING_DIR}/${GUEST_NAME}-metadata.yaml"

  # Download ubuntu 20.04 and change name
  wget "${CLOUD_INIT_IMAGE_URL}" -O "${IMAGE}"
}

resize_guest() {
  # Create backup of original image
  mv "${IMAGE}" "${IMAGE}_org"

  # Create new image with new size
  qemu-img create -f qcow2 -o preallocation=metadata "${IMAGE}" "${GUEST_SIZE_GB}G"
  
  # Determine the root partition name
  root_partition=$(virt-filesystems \
    --format=qcow2 \
    -a "${IMAGE}_org" \
    -l 2>/dev/null \
    | grep "${GUEST_ROOT_LABEL}" \
    | awk -F ' ' '{print $1}')

  [ -n "${root_partition}" ] || { >&2 echo -e "ERROR: Could not find guest root partition name"; return 1; }
  
  # Resize the guest root partition
  virt-resize --format=qcow2 --expand \
    "${root_partition}" \
    "${IMAGE}_org" \
    "${IMAGE}"

  # Remove original sized image
  rm -f "${IMAGE}_org"
}

extract_initrd() {
  local initrd_package="${1}"
  local initrd_extracted_dir="${2}"
  
  if [ -d "${initrd_extracted_dir}" ]; then
    echo -e "initrd directory exists, skipping extraction"
    return 0
  fi

  # Extract initrd package to directory  
  mkdir -p "${initrd_extracted_dir}"
  unmkinitramfs "${initrd_package}" "${initrd_extracted_dir}"
}

package_initrd() {
  local initrd_extracted_dir="${1}"
  local initrd_package="${2}"
  
  pushd "${initrd_extracted_dir}" >/dev/null
  
  # Add the first microcode firmware
  if [ -d "early" ]; then
    pushd "early" >/dev/null
    find . -print0 | cpio --null --create --format=newc > "${initrd_package}"
    popd >/dev/null
  fi

  # Add the second microcode firmware
  if [ -d "early2" ]; then
    pushd "early2" >/dev/null
    find kernel -print0 | cpio --null --create --format=newc >> "${initrd_package}"
    popd >/dev/null
  fi

  # Add the ram fs file system
  if [ -d "main" ]; then
    pushd "main" >/dev/null
    find . | cpio --create --format=newc | xz --format=lzma >> "${initrd_package}"
    popd >/dev/null
  fi
  popd >/dev/null
}

initrd_add_sev_guest_module() {
  local old_initrd="${1}"
  local initrd_extracted_dir="${LAUNCH_WORKING_DIR}/initrd-extracted"

  if [ -f "${GENERATED_INITRD_BIN}" ]; then
    echo -e "initrd previously generated, skipping the addition of the sev-guest module"
    return 0
  fi

  # Extract initrd to directory
  extract_initrd "${old_initrd}" "${initrd_extracted_dir}"
  
  # Add sev-guest module
  local initrd_drivers_path=$(realpath \
    ${initrd_extracted_dir}/main/usr/lib/modules/*/kernel/drivers \
    | head -1)
  cp -r "${SETUP_WORKING_DIR}/AMDSEV/linux/guest/drivers/virt" \
    "${initrd_drivers_path}"

  # Package initrd
  package_initrd "${initrd_extracted_dir}" "${GENERATED_INITRD_BIN}"
}

build_guest_initrd() {
  # Get directory name from tarball url
  local dracut_dir_name="dracut-$(echo "${DRACUT_TARBALL_URL}" | sed "s|.*\/\(.*\).tar.gz|\1|g")"
  local dracut="${SETUP_WORKING_DIR}/${dracut_dir_name}/dracut.sh"

  if [ ! -f "${dracut}" ]; then
    # Download, extract and establish path to binary
    wget "${DRACUT_TARBALL_URL}" -O "${SETUP_WORKING_DIR}/${dracut_dir_name}.tar.gz"
    tar xf "${SETUP_WORKING_DIR}/${dracut_dir_name}.tar.gz" -C "${SETUP_WORKING_DIR}"
    pushd "${SETUP_WORKING_DIR}/${dracut_dir_name}"
      ./configure
      make dracut
      sudo make dracut-install
    popd
  fi

  # Retrieve path to guest kernel, the version and modules directory location
  local guest_kernel=$(echo $(realpath "${SETUP_WORKING_DIR}/AMDSEV/linux/guest/debian/linux-image/boot/vmlinuz*"))
  local guest_kernel_version=$(echo "${guest_kernel}" | sed "s|.*/boot/vmlinuz-\(.*\)|\1|g")
  local guest_kernel_modules_dir=$(echo $(realpath "${SETUP_WORKING_DIR}/AMDSEV/linux/guest/debian/linux-image/lib/modules/*"))
  GENERATED_INITRD_BIN="${SETUP_WORKING_DIR}/initrd.img-${guest_kernel_version}"

  [[ ! -f "${GENERATED_INITRD_BIN}" ]] \
    || { echo -e "initrd.img-${guest_kernel_version} exists already, skipping initrd generation..."; return 0; }

  # Use dracut to build initrd
  "${dracut}" -f "${GENERATED_INITRD_BIN}" \
    --modules "systemd systemd-initrd kernel-modules base" \
    --no-early-microcode \
    --no-hostonly \
    --no-hostonly-cmdline \
    --reproducible \
    --kver "${guest_kernel_version}" \
    --kernel-image "${guest_kernel}" \
    --kmoddir "${guest_kernel_modules_dir}" \
    --kernel-cmdline "${GUEST_KERNEL_APPEND}" \
    --add-drivers "sev-guest"
}

save_binary_paths() {
  local guest_kernel=$(ls $(realpath "${SETUP_WORKING_DIR}/AMDSEV/linux/guest/debian/linux-image/boot/vmlinuz*"))
  local guest_kernel_version=$(ls "${guest_kernel}" | sed "s|.*/boot/vmlinuz-\(.*\)|\1|g")
  GENERATED_INITRD_BIN="${SETUP_WORKING_DIR}/initrd.img-${guest_kernel_version}"

# Save binary paths in source file
cat > "${SETUP_WORKING_DIR}/source-bins" <<EOF
QEMU_BIN="${SETUP_WORKING_DIR}/AMDSEV/qemu/build/qemu-system-x86_64"
OVMF_BIN="${SETUP_WORKING_DIR}/AMDSEV/ovmf/Build/AmdSev/DEBUG_GCC5/FV/OVMF.fd"
INITRD_BIN="${GENERATED_INITRD_BIN}"
KERNEL_BIN="${guest_kernel}"
EOF
}

add_qemu_cmdline_opts() {
  echo -e "\\" >> "${QEMU_CMDLINE_FILE}"
  echo -n "$* " >> "${QEMU_CMDLINE_FILE}"
}

build_base_qemu_cmdline() {
  # Return error if user specified file that doesn't exist
  qemu_bin="${1}"
  if [ ! -f "${qemu_bin}" ]; then
    >&2 echo -e "QEMU binary does not exist or was not specified"
    return 1
  fi

  # Create qemu files if they don't exist, set permissions
  touch "${LAUNCH_WORKING_DIR}/qemu.log"
  touch "${LAUNCH_WORKING_DIR}/qemu-trace.log"
  #touch "${LAUNCH_WORKING_DIR}/ovmf.log"
  touch "${QEMU_CMDLINE_FILE}"
  chmod +x "${QEMU_CMDLINE_FILE}"

  # Base cmdline
  echo -n "sudo ${qemu_bin} " > "${QEMU_CMDLINE_FILE}"
  add_qemu_cmdline_opts "--enable-kvm"
  # echo "Debug: QEMU_CPU_MODEL is ${QEMU_CPU_MODEL}"
  # echo "Debug: QEMU_CPU_NUM is ${QEMU_CPU_NUM}"
  # echo "Debug: QEMU_MEMORY_CAPACITY is ${QEMU_MEMORY_CAPACITY}"
  add_qemu_cmdline_opts "-cpu ${QEMU_CPU_MODEL}"
  add_qemu_cmdline_opts "-smp ${QEMU_CPU_NUM}"
  add_qemu_cmdline_opts "-m ${QEMU_MEMORY_CAPACITY}"
  add_qemu_cmdline_opts "-no-reboot"
  add_qemu_cmdline_opts "-vga std"
  add_qemu_cmdline_opts "-vnc :0"
  add_qemu_cmdline_opts "-monitor pty"
  add_qemu_cmdline_opts "-daemonize"

  # Networking
  add_qemu_cmdline_opts "-netdev user,hostfwd=tcp::${HOST_SSH_PORT}-:22,id=vmnic"
  add_qemu_cmdline_opts "-device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=vmnic,romfile="

  # Storage
  add_qemu_cmdline_opts "-device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=true"
  add_qemu_cmdline_opts "-device scsi-hd,drive=disk0"
  add_qemu_cmdline_opts "-drive if=none,id=disk0,format=qcow2,file=${IMAGE}"

  # qemu standard and trace logging
  add_qemu_cmdline_opts "-serial file:${LAUNCH_WORKING_DIR}/qemu.log"
  add_qemu_cmdline_opts "--trace \"kvm_sev*\""
  add_qemu_cmdline_opts "-D ${LAUNCH_WORKING_DIR}/qemu-trace.log"

  # ovmf logging
  # Will log to serial qemu.log file - hence comment ovmf.log line
  add_qemu_cmdline_opts "-global isa-debugcon.iobase=0x402"
  #add_qemu_cmdline_opts "-debugcon file:${LAUNCH_WORKING_DIR}/ovmf.log"
}

stop_guests() {
  local qemu_processes=$(sudo ps aux | grep "${WORKING_DIR}.*qemu.*${IMAGE}" | grep -v "tail.*qemu.log" | grep -v "grep.*qemu")
  [[ -n "${qemu_processes}" ]] || { echo -e "No qemu processes currently running"; return 0; }

  echo -e "Current running qemu process:"
  echo "${qemu_processes}"

  echo -e "\nKilling qemu process..."
  sudo pkill -9 -f "${WORKING_DIR}.*qemu.*${IMAGE}" || true
  sleep 3

  echo -e "Verifying no qemu processes running..."
  qemu_processes=$(sudo ps aux | grep "${WORKING_DIR}.*qemu.*${IMAGE}" | grep -v "tail.*qemu.log" | grep -v "grep.*qemu")

  [[ -z "${qemu_processes}" ]] || { >&2 echo -e "FAIL: qemu processes still exist:\n${qemu_processes}"; return 1; }
  echo -e "No qemu processes running!"
}

build_and_install_amdsev() {
  local amdsev_branch="${1:-${AMDSEV_DEFAULT_BRANCH}}"

  # Create directory
  mkdir -p "${SETUP_WORKING_DIR}"
  
  # Clone and switch branch
  pushd "${SETUP_WORKING_DIR}" >/dev/null
  if [ ! -d "AMDSEV" ]; then
    git clone -b "${amdsev_branch}" "${AMDSEV_URL}" "AMDSEV"
    git -C "AMDSEV" remote add current "${AMDSEV_URL}"
  fi

  # Fetch, checkout, update
  cd "AMDSEV"
  git remote set-url current "${AMDSEV_URL}"
  git fetch current "${amdsev_branch}"
  git checkout "current/${amdsev_branch}"

  # Build and copy files
  ./build.sh --package
  sudo cp kvm.conf /etc/modprobe.d/
  
  # Install
  cd $(ls -d snp-release-* | head -1)
  sudo ./install.sh
  
  popd >/dev/null

  # dracut initrd build is not working currently
  # Devices are failing to mount using the dracut built initrd
  # This step replaced by steps to install kernel and initrd in the guest during launch
  # Build the guest binary from the guest kernel
  #build_guest_initrd

  # Save binary paths in source file
  save_binary_paths
}

build_guest_amdsev() {
  local amdsev_branch="${1:-${AMDSEV_DEFAULT_BRANCH}}"

  # Create directory
  mkdir -p "${SETUP_WORKING_DIR}"
  
  # Clone and switch branch
  pushd "${SETUP_WORKING_DIR}" >/dev/null
  if [ ! -d "AMDSEV" ]; then
    git clone -b "${amdsev_branch}" "${AMDSEV_URL}" "AMDSEV"
    git -C "AMDSEV" remote add current "${AMDSEV_URL}"
  fi

  # Fetch, checkout, update
  cd "AMDSEV"
  git remote set-url current "${AMDSEV_URL}"
  git fetch current "${amdsev_branch}"
  git checkout "current/${amdsev_branch}"

  # Build and copy files
  ./build.sh qemu
  ./build.sh ovmf
  ./build.sh --package kernel guest
  # ./build.sh --package
  sudo cp kvm.conf /etc/modprobe.d/
  
  # Install
  cd $(ls -d snp-release-* | head -1)
  sudo ./install.sh
  
  popd >/dev/null

  # dracut initrd build is not working currently
  # Devices are failing to mount using the dracut built initrd
  # This step replaced by steps to install kernel and initrd in the guest during launch
  # Build the guest binary from the guest kernel
  #build_guest_initrd

  # Save binary paths in source file
  save_binary_paths
}

setup_and_launch_guest() {
  # Return error if user specified file that doesn't exist
  if [ ! -f "${IMAGE}" ] && ${SKIP_IMAGE_CREATE}; then
    >&2 echo -e "Image file specified, but doesn't exist"
    return 1
  fi

  # Create directory
  mkdir -p "${LAUNCH_WORKING_DIR}"

  # Build base qemu cmdline and add direct boot bins
  build_base_qemu_cmdline "${QEMU_BIN}"

  # If the image file doesn't exist, setup
  if [ ! -f "${IMAGE}" ]; then
    generate_guest_ssh_keypair
    cloud_init_create_data
    
    # virt-resize currently does not work with cloud-init images
    # It changes the partition names and grub gets messed up
    #resize_guest

    # For the cloud-init image, just resize the image
    qemu-img resize "${LAUNCH_WORKING_DIR}/${GUEST_NAME}.img" "${GUEST_SIZE_GB}G"

    # Add seed image option to qemu cmdline
    add_qemu_cmdline_opts "-device scsi-hd,drive=disk1"
    add_qemu_cmdline_opts "-drive if=none,id=disk1,format=raw,file=${LAUNCH_WORKING_DIR}/${GUEST_NAME}-seed.img"
  fi

  local guest_kernel_installed_file="${LAUNCH_WORKING_DIR}/guest_kernel_already_installed"
  if [ ! -f "${guest_kernel_installed_file}" ]; then
    # Launch qemu cmdline
    "${QEMU_CMDLINE_FILE}"

    # Install the guest kernel, retrieve the initrd and then reboot
    local guest_kernel=$(echo $(realpath "${SETUP_WORKING_DIR}/AMDSEV/linux/guest/debian/linux-image/boot/vmlinuz*"))
    local guest_kernel_version=$(echo "${guest_kernel}" | sed "s|.*/boot/vmlinuz-\(.*\)|\1|g")
    local guest_kernel_deb=$(echo "$(realpath ${SETUP_WORKING_DIR}/AMDSEV/linux/linux-image*snp-guest*.deb)" | grep -v dbg)
    local guest_initrd_basename="initrd.img-${guest_kernel_version}"
    wait_and_retry_command "scp_guest_command ${guest_kernel_deb} ${GUEST_USER}@localhost:/home/${GUEST_USER}"
    ssh_guest_command "sudo dpkg -i /home/${GUEST_USER}/$(basename ${guest_kernel_deb})"
    scp_guest_command "${GUEST_USER}@localhost:/boot/${guest_initrd_basename}" "${SETUP_WORKING_DIR}"
    ssh_guest_command "sudo shutdown now" || true
    echo "true" > "${guest_kernel_installed_file}"

    # A few seconds for shutdown to complete
    sleep 3

    # Call the launch-guest again now that the image is prepped
    setup_and_launch_guest
    return 0
  fi

  # Add sev-guest module to host generated initrd
  # To be used as the guest initrd
  # NO LONGER NEEDED: initrd built after kernel generation (build_guest_initrd)
  #initrd_add_sev_guest_module "${INITRD_BIN}"

  if $UPM; then
    add_qemu_cmdline_opts "-machine confidential-guest-support=sev0,memory-backend=ram1,kvm-type=protected"
    add_qemu_cmdline_opts "-object memory-backend-memfd-private,id=ram1,size=1G,share=true"
  else
    add_qemu_cmdline_opts "-machine memory-encryption=sev0,vmport=off"
  fi

  # qemu 7.2 issue: pc-q35-7.1
  # snp object and kernel-hashes on
  # ovmf, initrd, kernel and append options
  add_qemu_cmdline_opts "-machine pc-q35-7.1"
  add_qemu_cmdline_opts "-object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1,kernel-hashes=on"
  add_qemu_cmdline_opts "-drive if=pflash,format=raw,readonly=on,file=${OVMF_BIN}"
  add_qemu_cmdline_opts "-initrd ${INITRD_BIN}"
  add_qemu_cmdline_opts "-kernel ${KERNEL_BIN}"
  add_qemu_cmdline_opts "-append \"${GUEST_KERNEL_APPEND}\""

  # Launch qemu cmdline
  "${QEMU_CMDLINE_FILE}"
}

setup_guest() {
  # Return error if user specified file that doesn't exist
  if [ ! -f "${IMAGE}" ] && ${SKIP_IMAGE_CREATE}; then
    >&2 echo -e "Image file specified, but doesn't exist"
    return 1
  fi

  # Create directory
  mkdir -p "${LAUNCH_WORKING_DIR}"

  # Build base qemu cmdline and add direct boot bins
  build_base_qemu_cmdline "${QEMU_BIN}"

  # echo "GUEST_SIZE_GB is set to: ${GUEST_SIZE_GB}"

  # If the image file doesn't exist, setup
  if [ ! -f "${IMAGE}" ]; then
    generate_guest_ssh_keypair
    cloud_init_create_data
    
    # virt-resize currently does not work with cloud-init images
    # It changes the partition names and grub gets messed up
    #resize_guest

    # For the cloud-init image, just resize the image
    qemu-img resize "${LAUNCH_WORKING_DIR}/${GUEST_NAME}.img" "${GUEST_SIZE_GB}G"

    # Add seed image option to qemu cmdline
    add_qemu_cmdline_opts "-device scsi-hd,drive=disk1"
    add_qemu_cmdline_opts "-drive if=none,id=disk1,format=raw,file=${LAUNCH_WORKING_DIR}/${GUEST_NAME}-seed.img"
  fi

  local guest_kernel_installed_file="${LAUNCH_WORKING_DIR}/guest_kernel_already_installed"

  # Add sev-guest module to host generated initrd
  # To be used as the guest initrd
  # NO LONGER NEEDED: initrd built after kernel generation (build_guest_initrd)
  #initrd_add_sev_guest_module "${INITRD_BIN}"

  if $UPM; then
    add_qemu_cmdline_opts "-machine confidential-guest-support=sev0,memory-backend=ram1,kvm-type=protected"
    add_qemu_cmdline_opts "-object memory-backend-memfd-private,id=ram1,size=1G,share=true"
  else
    add_qemu_cmdline_opts "-machine memory-encryption=sev0,vmport=off"
  fi

  # qemu 7.2 issue: pc-q35-7.1
  # snp object and kernel-hashes on
  # ovmf, initrd, kernel and append options
  add_qemu_cmdline_opts "-machine pc-q35-7.1"
  add_qemu_cmdline_opts "-object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1,kernel-hashes=on"
  add_qemu_cmdline_opts "-drive if=pflash,format=raw,readonly=on,file=${OVMF_BIN}"
  add_qemu_cmdline_opts "-initrd ${INITRD_BIN}"
  add_qemu_cmdline_opts "-kernel ${KERNEL_BIN}"
  add_qemu_cmdline_opts "-append \"${GUEST_KERNEL_APPEND}\""

  # Launch qemu cmdline
  # "${QEMU_CMDLINE_FILE}"
}

ssh_guest_command() {
  [ -n "${1}" ] || { >&2 echo -e "No guest command specified"; return 1; }

  # Remove fail on error
  set +eE; set +o pipefail

  {
    IFS=$'\n' read -r -d '' CAPTURED_STDERR;
    IFS=$'\n' read -r -d '' CAPTURED_STDOUT;
    (IFS=$'\n' read -r -d '' _ERRNO_; return ${_ERRNO_});
  } < <((printf '\0%s\0%d\0' "$(ssh -p ${HOST_SSH_PORT} \
    -i ${GUEST_SSH_KEY_PATH} \
    -o "StrictHostKeyChecking no" \
    -o "PasswordAuthentication=no" \
    -o ConnectTimeout=1 \
    -t ${GUEST_USER}@localhost \
    "${1}")" "${?}" 1>&2) 2>&1)

  local return_code=$?

  # Reset fail on error
  set -eE; set -o pipefail

  [[ $return_code -eq 0 ]] \
    || { >&2 echo "${CAPTURED_STDOUT}"; >&2 echo "${CAPTURED_STDERR}"; return ${return_code}; }
  echo "${CAPTURED_STDOUT}"
}

scp_guest_command() {
  [ -n "${1}" ] || { >&2 echo -e "No scp source specified"; return 1; }
  [ -n "${2}" ] || { >&2 echo -e "No scp target specified"; return 1; }

  scp -r -P ${HOST_SSH_PORT} \
    -i ${GUEST_SSH_KEY_PATH} \
    -o "StrictHostKeyChecking no" \
    -o "PasswordAuthentication=no" \
    -o ConnectTimeout=1 \
    "${1}" "${2}"
}

verify_snp_guest() {
  # Exit if SSH private key does not exist
  if [ ! -f "${GUEST_SSH_KEY_PATH}" ]; then
    >&2 echo -e "SSH key not present [${GUEST_SSH_KEY_PATH}], cannot verify guest SNP enabled"
    return 1
  fi

  # Look for SNP enabled in guest dmesg output
  local snp_dmesg_grep_text="Memory Encryption Features active:.*SEV-SNP"
  local snp_enabled=$(ssh_guest_command "sudo dmesg | grep \"${snp_dmesg_grep_text}\"")

  [[ -n "${snp_enabled}" ]] \
    && { echo "DMESG REPORT: ${snp_enabled}"; echo -e "SNP is Enabled"; } \
    || { >&2 echo -e "SNP is NOT Enabled"; return 1; }
}

wait_and_verify_snp_guest() {
  local max_tries=30
  
  for ((i=1; i<=${max_tries}; i++)); do
    if ! (verify_snp_guest >/dev/null 2>&1); then
      sleep 1
      continue
    fi
    verify_snp_guest
    return 0
  done
  
  >&2 echo -e "ERROR: Timed out trying to connect to guest"
  return 1
}

wait_and_retry_command() {
  local command="${1}"
  local max_tries=30
  
  for ((i=1; i<=${max_tries}; i++)); do
    if ! (${command} >/dev/null 2>&1); then
      sleep 1
      continue
    fi
    ${command}
    return 0
  done
  
  >&2 echo -e "ERROR: Timed out trying to connect to guest"
  return 1
}

setup_guest_attestation() {
  # Create directory
  mkdir -p "${ATTESTATION_WORKING_DIR}"
  pushd "${ATTESTATION_WORKING_DIR}" >/dev/null

  local branch_no_tags=$(echo "${SNPGUEST_BRANCH}" | sed "s|tags/||g")

  if [ ! -d "snpguest" ]; then
    git clone -b "${branch_no_tags}" "${SNPGUEST_URL}" "snpguest"
    git -C "snpguest" remote add current "${SNPGUEST_URL}"
  fi

  # Fetch, checkout, update
  cd "snpguest"
  git remote set-url current "${SNPGUEST_URL}"
  git fetch current "${SNPGUEST_BRANCH}"
  
  # Handle checkout if tag is specified
	if [[ "${SNPGUEST_BRANCH}" =~ "tags/" ]]; then
		git checkout "${SNPGUEST_BRANCH}"
	else
		git checkout "current/${SNPGUEST_BRANCH}"
	fi

  cargo build -r
  scp_guest_command target/release/snpguest "${GUEST_USER}@localhost:/home/${GUEST_USER}"
  popd

  # Update, upgrade and packages
  local guest_setup_file="${WORKING_DIR}/guest_already_setup"
  
  if [ -f "${guest_setup_file}" ]; then
    echo -e "Guest previously setup"
    return 0
  fi
  
  # For now, not needed
  # This may be needed later if any additional steps are to be performed on the guest
  #ssh_guest_command "sudo apt update -y && sudo apt upgrade -y"
  echo "true" > "${guest_setup_file}"
}

get_cpu_code_name() {
  local cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d ' ' -f5)
  local cpu_code_name="milan"

  case "${cpu_model}" in
    7*)
      cpu_code_name="milan"
      echo $cpu_code_name
      ;;
    9*)
      cpu_code_name="genoa"
      echo $cpu_code_name
      ;;
    *)
      >&2 echo -e "Unknown CPU Model: ${cpu_model}"
      return 1
      ;;
  esac
}

generate_snp_expected_measurement() {
  # Get ovmf, kernel, initrd paths
  # Get vcpu type and kernel append command line
  local ovmf_path=$(cat "${QEMU_CMDLINE_FILE}" \
    | grep "OVMF.fd" \
    | cut -d ' ' -f2 \
    | sed "s|.*file=\(.*\)|\1|g")
  local kernel_path=$(cat "${QEMU_CMDLINE_FILE}" \
    | grep "\-kernel" \
    | cut -d ' ' -f2)
  local initrd_path=$(cat "${QEMU_CMDLINE_FILE}" \
    | grep "\-initrd" \
    | cut -d ' ' -f2)
  local append=$(cat "${QEMU_CMDLINE_FILE}" \
    | grep "\-append" \
    | cut -d '"' -f2)
  local vcpus=$(cat "${QEMU_CMDLINE_FILE}" \
    | grep "\-smp" \
    | cut -d ' ' -f2)
  local vcpu_type=$(cat "${QEMU_CMDLINE_FILE}" \
    | grep "\-cpu" \
    | cut -d ' ' -f2)

  # Return error if files don't exist
  [ -f "${ovmf_path}" ] || \
    { >&2 echo -e "OVMF path specified does not exist: ${ovmf_path}"; return 1; }
  [ -f "${kernel_path}" ] || \
    { >&2 echo -e "kernel path specified does not exist: ${kernel_path}"; return 1; }
  [ -f "${initrd_path}" ] || \
    { >&2 echo -e "initrd path specified does not exist: ${initrd_path}"; return 1; }

  # Generate digest from sev-snp-measure output
  # PATH setting here needed for pip installed binary to be found
  measurement=$(PATH="${PATH}:${HOME}/.local/bin" sev-snp-measure \
    --mode=snp \
    --vcpus="${vcpus}" \
    --vcpu-type="${vcpu_type}" \
    --output-format=hex \
    --ovmf="${ovmf_path}" \
    --kernel="${kernel_path}" \
    --initrd="${initrd_path}" \
    --append="${append}" \
  )
  [[ -n "${measurement}" ]] || \
    { >&2 echo -e "sev-snp-measure return value is empty"; return 1; }
  echo ${measurement}
}

attest_guest() {
  local cpu_code_name=$(get_cpu_code_name)

  # Install the sev-guest module
  ssh_guest_command "sudo insmod /lib/modules/*/kernel/drivers/virt/coco/sev-guest/sev-guest.ko >/dev/null 2>&1 || true"

  # Request and display the snp attestation report with random data
  ssh_guest_command "sudo ./snpguest report --random"
  ssh_guest_command "./snpguest display report"

  # Retrieve ark, ask, vcek (saved in ./certs)
  ssh_guest_command "./snpguest fetch ca ${cpu_code_name} ."
  ssh_guest_command "./snpguest fetch vcek ${cpu_code_name} ."

  # Verifies that ARK, ASK and VCEK are all properly signed
  ssh_guest_command "./snpguest verify certs ."

  # Verifies the attestation-report trusted compute base matches vcek
  ssh_guest_command "./snpguest verify tcb ."

  # Verifies the attestation report was signed by the vcek
  ssh_guest_command "./snpguest verify signature ."

  # Use sev-snp-measure utility to calculate the expected measurement
  local expected_measurement=$(generate_snp_expected_measurement)
  echo -e "\nExpected Measurement (sev-snp-measure):  ${expected_measurement}"

  # Parse the measurement out of the snp report
  local snpguest_report_measurement=$(ssh_guest_command \
    "./snpguest display report \
    | tr '\n' ' ' \
    | sed \"s|.*Measurement:\(.*\)Host Data.*|\1\n|g\" \
    | sed \"s| ||g\"")

  # Remove any special characters and print the value
  snpguest_report_measurement=$(echo ${snpguest_report_measurement} | sed $'s/[^[:print:]\t]//g')
  echo -e "Measurement from SNP Attestation Report: ${snpguest_report_measurement}\n"

  # Compare the expected measurement to the guest report measurement
  [[ "${expected_measurement}" == "${snpguest_report_measurement}" ]] \
    && echo -e "The expected measurement matches the snp guest report measurement!" \
    || { >&2 echo -e "FAIL: measurements do not match"; return 1; }
}



###############################################################################

# Main

main() {
  # A command must be specified
  if [ -z "${1}" ]; then
    usage
    return 1
  fi

  # Create working directory
  mkdir -p "${WORKING_DIR}"
  
  # Parse command args and options
  while [ -n "${1}" ]; do
    case "${1}" in
      -h|--help)
        usage
        ;;

      -n|--non-upm)
        UPM=false
        shift
        ;;

      -i|--image)
        IMAGE="${2}"
        SKIP_IMAGE_CREATE=true
        shift; shift
        ;;

      setup-host)
        COMMAND="setup-host"
        shift
        ;;

      launch-guest)
        COMMAND="launch-guest"
        shift
        ;;
      
      build-guest)
        COMMAND="build-guest"
        shift
        ;;

      attest-guest)
        COMMAND="attest-guest"
        shift
        ;;

      stop-guests)
        COMMAND="stop-guests"
        shift
        ;;

      -*|--*)
        >&2 echo -e "Unsupported Option: [${1}]\n"
        usage
        return 1
        ;;

      *)
        >&2 echo -e "Unsupported Command: [${1}]\n"
        usage
        return 1
        ;;
    esac
  done
  
  # Set SETUP_WORKING_DIR for non-upm
  if ! $UPM; then
    SETUP_WORKING_DIR="${SETUP_WORKING_DIR}/non-upm"
  fi

  # Execute command
  case "${COMMAND}" in
    help)
      usage
      return 1
      ;;

    setup-host)
      install_dependencies

      if $UPM; then
        build_and_install_amdsev "${AMDSEV_DEFAULT_BRANCH}"
      else
        build_and_install_amdsev "${AMDSEV_NON_UPM_BRANCH}"
      fi

      source "${SETUP_WORKING_DIR}/source-bins"
      set_grub_default_snp
      echo -e "\nThe host must be rebooted for changes to take effect"
      ;;

    launch-guest)
      if [ ! -d "${SETUP_WORKING_DIR}" ]; then
        echo -e "Setup directory does not exist, please run 'setup-host' prior to 'launch-guest'"
        return 1
      fi
      source "${SETUP_WORKING_DIR}/source-bins"

      verify_snp_host
      install_dependencies
      setup_and_launch_guest
      wait_and_retry_command verify_snp_guest
      ;;
    
    build-guest)
      install_dependencies

      if $UPM; then
        build_guest_amdsev "${AMDSEV_DEFAULT_BRANCH}"
      else
        build_guest_amdsev "${AMDSEV_NON_UPM_BRANCH}"
      fi
      if [ ! -d "${SETUP_WORKING_DIR}" ]; then
        echo -e "Setup directory does not exist, please run 'setup-host' prior to 'launch-guest'"
        return 1
      fi
      source "${SETUP_WORKING_DIR}/source-bins"

      setup_guest
      ;;

    attest-guest)
      install_dependencies
      wait_and_retry_command verify_snp_guest
      setup_guest_attestation
      attest_guest
      ;;

    stop-guests)
      stop_guests
      ;;

    *)
      >&2 echo -e "Unsupported Command: [${1}]\n"
      usage
      return 1
      ;;
  esac
}


main "${@}"

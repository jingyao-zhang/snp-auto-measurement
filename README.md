# Automatic Measurement and Provisioning Utility for AMD SEV-SNP

This repository contains utility scripts to automate the setup and operation of virtualized environments using AMD's Secure Encrypted Virtualization - Secure Nested Paging (SEV-SNP). The utility provides a complete flow for creating an SEV-SNP-enabled environment, from provisioning the host machine to calculating measurements for a modified guest image, kernel, and OVMF.

## Acknowledgments

This utility script (`snp.sh`) is adapted from [sev-utils](https://github.com/amd/sev-utils).

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
  - [Host Setup](#host-setup)
  - [Launching a Guest](#launching-a-guest)
  - [Attesting a Guest](#attesting-a-guest)
  - [Stopping All Guests](#stopping-all-guests)
  - [Using Your Own Image](#using-your-own-image)
  - [SSH Access to Guest](#ssh-access-to-guest)
  - [Measurement Calculation](#measurement-calculation)
- [Caveats and Warnings](#caveats-and-warnings)
- [Contributing](#contributing)
- [License](#license)

## Overview

The utility performs the following tasks:

1. Provisions an AMD EPYC CPU-powered server by building the required patched versions of qemu, OVMF, and the Linux kernel.
2. Allows for the launching of an SNP-enabled guest directly with QEMU.
3. Facilitates attestation of the SNP guest using the [virtee/snpguest](https://github.com/virtee/snpguest) CLI tool.

**Tested OS Distributions:**
- Ubuntu 20.04
- Ubuntu 22.04

**Supported Image Formats:**
- qcow2

## Prerequisites

- Enable SNP features on your AMD EPYC CPU from the system BIOS. Follow the [detailed instructions](#enable-host-snp-options-in-the-system-bios) for enabling these options.

## Installation

Clone this repository and navigate to its directory:

```bash
git clone https://github.com/your-repo-link
cd your-repo-directory
```

Make the script executable:

```bash
chmod +x snp.sh
```

## Usage

### Host Setup

To set up the host with the default UPM-enabled version of the kernel:

```bash
./snp.sh setup-host
```

For users who require support for Confidential Containers (CoCo), which currently does not support UPM, use the `--non-upm` option:

```bash
./snp.sh setup-host --non-upm
```

### Build Guest OVMF, Kernel, and Image Only

If you only need to build the guest OVMF, kernel, and image, use the following command:

```bash
./snp.sh build-guest
```

Note that only buiding OVM, guest kernel and image does not require KVM supported. 

This command is also used in Github Actions for automatic measurement calculation.

### Launching a Guest

To launch a guest with the default UPM-enabled version of the kernel:

```bash
./snp.sh launch-guest
```

Again, for CoCo users, specify the `--non-upm` option if you've set up the host using the same:

```bash
./snp.sh launch-guest --non-upm
```

**Note:** If you intend to use the `--non-upm` option for launching a guest, ensure you've also used it during the host setup phase.

### Attesting a Guest

```bash
./snp.sh attest-guest
```

### Stopping All Guests

```bash
./snp.sh stop-guests
```

### Using Your Own Image

To use your own guest image, set these environment variables:

```bash
export IMAGE="guest.img"
export GUEST_USER="user"
export GUEST_SSH_KEY_PATH="guest-key"
```

And then:

```bash
./snp.sh launch-guest
```

### SSH Access to Guest

```bash
ssh -p 10022 -i snp-guest-key amd@localhost
```

### Measurement Calculation

Generate the golden measurement with:

```bash
chmod +x cal-measurement.sh
./cal-measurement.sh
```

## Caveats and Warnings

1. The script installs developer packages. Check `install_dependencies` for admin concerns.
2. Grub settings will be modified.

#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root" >&2
        log_error "Please run: sudo $0" >&2
        exit 1
    fi
    log_info "Running as root - OK"
}

find_tmp_device() {
    local tpm_device
    if ! tpm_device=$(systemd-cryptenroll --tpm2-device=list | tail -n1 | awk '{ print $1 }'); then
        log_error "Failed to get available TPM devices" >&2
        exit 1
    fi

    echo $tpm_device
}

find_luks_partition() {
    local devices
    if ! devices=$(systemd-cryptenroll --list-devices 2>/dev/null); then
        log_error "Failed to list LUKS devices. Ensure systemd-cryptenroll is available." >&2
        exit 1
    fi

    local luks_devices=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^/dev/ ]] && [[ ! "$line" =~ ^/dev/disk/by- ]]; then
            luks_devices+=("$line")
        fi
    done <<< "$devices"

    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        log_error "No LUKS devices found" >&2
        exit 1
    elif [[ ${#luks_devices[@]} -eq 1 ]]; then
        echo "${luks_devices[0]}"
    else
        log_info "Multiple LUKS devices found:" >&2
        for i in "${!luks_devices[@]}"; do
            echo "$((i+1)). ${luks_devices[i]}" >&2
        done
        echo >&2
        read -p "Select device number (1-${#luks_devices[@]}): " selection >&2

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#luks_devices[@]} ]]; then
            local selected_device="${luks_devices[$((selection-1))]}"
            echo "$selected_device"
        else
            log_error "Invalid selection" >&2
            exit 1
        fi
    fi
}

main() {
    check_root

    TPM_DEVICE=$(find_tmp_device)
    LUKS_PARTITION=$(find_luks_partition)
    LUKS_DEV_UUID="$(cryptsetup luksUUID "$LUKS_PARTITION")"
    DEVICE_PATH="/dev/disk/by-uuid/${LUKS_DEV_UUID}"
    # See https://wiki.archlinux.org/title/Trusted_Platform_Module#Accessing_PCR_registers
    # for all available PCR registers
    TPM_PRCS="0+2+4+7+8+9+15:sha256=0000000000000000000000000000000000000000000000000000000000000000"
    TPM_PIN_REQUIRED="false"

    log_info "==================="
    log_info "LUKS Partition    : $LUKS_PARTITION"
    log_info "LUKS UUID         : $LUKS_DEV_UUID"
    log_info "LUKS Device Path  : $DEVICE_PATH"
    log_info "TPM Device        : $TPM_DEVICE"
    log_info "TPM PCRs          : $TPM_PRCS"
    log_info "TPM Pin Required  : $TPM_PIN_REQUIRED"
    log_info "==================="

     # Backup existing crypttab
    if [[ -f /etc/crypttab ]]; then
        log_info "Backing up existing /etc/crypttab"
        cp /etc/crypttab /etc/crypttab.backup.$(date +%Y%m%d_%H%M%S)
    fi

    # Update crypttab
    log_info "Updating /etc/crypttab..."
    echo "luks-${LUKS_DEV_UUID} UUID=${LUKS_DEV_UUID} - tpm2-device=${TPM_DEVICE},discard" > /etc/crypttab

    # Update grub config
    log_info "Updating GRUB configuration..."
    grubby --update-kernel=ALL --args="rd.luks.options=tpm2-device=$TPM_DEVICE,tpm2-measure-pcr=yes"
    grub2-mkconfig -o /boot/grub2/grub.cfg

    # Regenerate initramfs
    log_info "Regenerating initramfs using dracut..."
    dracut --force --regenerate-all

    # Ask about removing existing TPM2 keys
    read -p "Do you want to remove any existing TPM2 keys? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing existing TPM2 keys..."
        systemd-cryptenroll "$DEVICE_PATH" --wipe-slot tpm2 || {
            log_warn "Could not wipe TPM2 slots (maybe none exist)" >&2
        }
    fi

    read -p "Do you want enroll your TPM2 device? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        exit 1;
    fi

    # Enroll TPM
    log_info "Enrolling TPM2 device $TPM_DEVICE using PCRs $TPM_PRCS..."
    systemd-cryptenroll \
        "$DEVICE_PATH" \
        --tpm2-device=$TPM_DEVICE \
        --tpm2-pcrs=${TPM_PRCS} \
        --tpm2-with-pin=${TPM_PIN_REQUIRED} || {
            log_error "Could not enroll TPM2" >&2
            exit 1
        }

    log_info "Enrolled successfully! You may now reboot"
}

cleanup() {
    echo >&2
    log_warn "Script interrupted" >&2
    exit 1
}

trap cleanup SIGINT SIGTERM
main "$@"

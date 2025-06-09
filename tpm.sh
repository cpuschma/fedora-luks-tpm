#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_TPM_PRCS="7+8"
DEFAULT_TPM_PIN_REQUIRED="false"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Configure TPM2-based LUKS disk encryption.

OPTIONS:
    -d, --device               LUKS Block Device to use
    -p, --pcrs PCR_LIST        TPM PCR registers to use (default: $DEFAULT_TPM_PRCS)
    -i, --pin BOOLEAN          Require PIN for TPM unlock (true/false, default: $DEFAULT_TPM_PIN_REQUIRED)
    -h, --help                 Show this help message

EXAMPLES:
    $0                                  # Use default settings
    $0 --device /dev/sda1               # Use explicitly device /dev/sda1
    $0 --pcrs "0+7"                     # Use only PCRs 0 and 7
    $0 --pin true                       # Require PIN for unlock
    $0 --pcrs "0+2+7" --pin true        # Custom PCRs with PIN required

PCR Register Information:
    0   - SRTM, BIOS, Host Platform Extensions
    1   - Host Platform Configuration
    2   - UEFI driver and variable data
    4   - UEFI Boot Manager Code and Boot Attempts
    7   - Secure Boot State
    8   - GRUB2 bootloader
    9   - GRUB2 loaded files (kernel, initramfs)
    15  - System Locality

For more details, see: https://wiki.archlinux.org/title/Trusted_Platform_Module#Accessing_PCR_registers
EOF
}

parse_arguments() {
    TPM_PRCS="$DEFAULT_TPM_PRCS"
    TPM_PIN_REQUIRED="$DEFAULT_TPM_PIN_REQUIRED"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--pcrs)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    exit 1
                fi
                TPM_PRCS="$2"
                shift 2
                ;;
            -i|--pin)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    exit 1
                fi
                case "${2,,}" in
                    true|yes|1)
                        TPM_PIN_REQUIRED="true"
                        ;;
                    false|no|0)
                        TPM_PIN_REQUIRED="false"
                        ;;
                    *)
                        log_error "Invalid value for --pin: $2 (use true/false)"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -d|--device)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    exit 1
                fi
                LUKS_PARTITION="$2"

                # Check if the file is a block device
                if [[ ! -b "$LUKS_PARTITION" ]]; then
                    log_error "Device '${LUKS_PARTITION}' is not a valid block device"
                    exit 1
                fi

                # Check if it's a LUKS device
                if ! cryptsetup isLuks "$LUKS_PARTITION" 2>/dev/null; then
                    log_error "Device '$LUKS_PARTITION' is not a LUKS encrypted device"
                    exit 1
                fi

                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    local required_commands=("systemd-cryptenroll" "cryptsetup" "grubby" "grub2-mkconfig" "dracut")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:" >&2
        for dep in "${missing_deps[@]}"; do
            log_error "  - $dep" >&2
        done
        log_error ""
        log_error "Please install the missing packages:" >&2
        log_error "  sudo dnf install systemd cryptsetup-luks grubby grub2-tools dracut" >&2
        exit 1
    fi
    
    log_info "All required dependencies found - OK"
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
    parse_arguments "$@"
    check_root
    check_dependencies

    TPM_DEVICE=$(find_tmp_device)
    LUKS_PARTITION="${LUKS_PARTITION:-$(find_luks_partition)}"
    LUKS_DEV_UUID="$(cryptsetup luksUUID "$LUKS_PARTITION")"
    DEVICE_PATH="/dev/disk/by-uuid/${LUKS_DEV_UUID}"

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
        --tpm2-device=${TPM_DEVICE} \
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

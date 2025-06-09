# Enroll your TPM to unlock your LUKS partition

Use the following script to automatically prepare your system to decrypt your LUKS partition using your TPM2.

## Use:
```bash
curl -O -J https://raw.githubusercontent.com/cpuschma/fedora-luks-tpm/refs/heads/master/tpm.sh
chmod u+x ./tpm.sh
sudo ./tpm.sh
```
 
 You may edit [any configuration](https://github.com/cpuschma/fedora-luks-tpm/blob/82ca8bfee330ba0fdfc38a2d18b6b5bdfdbe63c7/tpm.sh#L82), like the used PCRs or PIN requirement in the main function. 

## Demo
https://github.com/user-attachments/assets/4d455c6e-dd8a-4910-a77d-951b39e6af55

## Tested on:
- Fedora 42

## Requirements:
- Bash
- systemd-cryptenroll (should be installed by default on Fedora)
- A TPM2 module
- One or more LUKS partitions
- Your current LUKS password

# FAQ 

### What happens if my TPM refuses to unlock automatically or if the chip is destroyed

If the chip refuses to decrypt — for example, if a PCR register has changed, such as Secure Boot, or if the chip is broken — then a password prompt is offered as a fallback option, or a key file is requested (depending on your setup).

> [!CAUTION]
> Keep your password or your keyfile save, even if the TPM is set up, just as you should keep the BitLocker recovery key in Microsoft Windows.

### What does this script do?
- If not otherwise defined, find a suitable LUKS partition and TPM device
- (If one already exists) Make a backup of your /etc/crypttab
- Configure your /etc/crypttab to use the TPM device
- Update your grub configuration to use the TPM device and enable TPM measurement
- Regenerate your initramfs using dracut
- (optionally) Remove any already enrolled TPM2 devices
- Enroll your TPM2

#!/bin/bash
# LUKS TPM sealed passphrase keyslot
do_luks(){
    echo
    read -s -p "Please enter the final LUKS passphrase: " FINAL_PASSPHRASE
    echo
    read -s -p "Please confirm the final LUKS passphrase: " CONFIRMED_PASSPHRASE
    echo
    if [ "$FINAL_PASSPHRASE" != "$CONFIRMED_PASSPHRASE" ]; then
        echo "Passphrases do not match. Exiting."
        return
    fi
    echo "Passphrases match. Proceeding with LUKS key addition and TPM2 binding..."
    printf "%s" "$FINAL_PASSPHRASE" | cryptsetup luksAddKey /dev/nvme0n1p5 --key-file /etc/cryptsetup-keys.d/luks_password.txt
    printf "%s" "$FINAL_PASSPHRASE" | clevis luks bind -d /dev/nvme0n1p5 tpm2 '{"pcr_bank":"sha256"}' -k -
    echo "dm_crypt-0 UUID=$(blkid -s UUID -o value /dev/nvme0n1p5) none luks" | tee /etc/crypttab
    update-initramfs -u
    echo "binding and update complete, deleting previous all other keys and current script..."
    cryptsetup luksRemoveKey /dev/nvme0n1p5 --key-file /etc/cryptsetup-keys.d/dm_crypt-0.key
    cryptsetup luksRemoveKey /dev/nvme0n1p5 --key-file /etc/cryptsetup-keys.d/luks_password.txt
    rm /etc/cryptsetup-keys.d/luks_password.txt
    rm /etc/cryptsetup-keys.d/dm_crypt-0.key
    rm /etc/cryptsetup-keys.d/init.sh
    rm -dfr /etc/cryptsetup-keys.d
}
# GRUB Protection
do_grub(){
    # Password Protection
    read -r -s -p "set GRUB password: " GRUB_PASSWORD
    echo
    read -r -s -p "confirm GRUB password: " GRUB_PASSWORD_CONFIRM
    echo
    if [ "$GRUB_PASSWORD" != "$GRUB_PASSWORD_CONFIRM" ]; then
        echo "Passwords do not match. Exiting."
        return
    fi
    unset GRUB_PASSWORD_CONFIRM
    GRUB_HASH=$(echo "$GRUB_PASSWORD" | grub-mkpasswd-pbkdf2 | tail -n 1 | awk '{print $NF}')
    unset GRUB_PASSWORD
    CONFIG_LINES=$(cat ./helpers/40_custom)
    printf '%s\n' "$CONFIG_LINES" | sed -i '1i\
        set superusers="admin"\
        password_pbkdf2 '"admin"' '"${GRUB_HASH}"'' "/etc/grub.d/40_custom"
    # make that password required for any menuentry other than normal boot
    sed -i 's/echo "menuentry '\''\$(echo "\$os" | grub_quote)'\'' \$\{CLASS\}/echo "menuentry '\''\$(echo "\$os" | grub_quote)'\'' --unrestricted \$\{CLASS\}/' /etc/grub.d/10_linux
    # Enforcing memory boundaries for devices
    sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="intel_iommu=on"/' /etc/default/grub
    update-grub
}
# tty1 login
do_tty1(){
    # disable tty1 login
    systemctl mask getty@tty1.service
    echo "user" | tee /etc/denied_console_users
    chmod 644 /etc/denied_console_users
    sed -i '/#auth required/a auth required pam_listfile.so item=user sense=deny file=\/etc\/denied_console_users onerr=succeed' /etc/pam.d/login
    # general SSH config adjustments
    if [[ -f /home/user/.ssh/authorized_keys && -s /home/user/.ssh/authorized_keys ]]; then
        sed -i 's|^#\?\(PasswordAuthentication\s\+\)\(yes\|no\).*$|\1no|; s|^#\?\(KbdInteractiveAuthentication\s\+\)\(yes\|no\).*$|\1no|' /etc/ssh/sshd_config
        if ! grep -q "^Match User user" /etc/ssh/sshd_config; then
            printf "\nMatch User user\n    AuthenticationMethods publickey\n" | tee -a /etc/ssh/sshd_config
        fi
        systemctl restart ssh
    fi
}

do_luks
do_grub
do_tty1
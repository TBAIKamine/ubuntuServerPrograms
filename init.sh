#!/bin/bash
# LUKS TPM sealed passphrase keyslot
do_luks(){
    apt update -y && apt install clevis clevis-tpm2 clevis-luks clevis-initramfs -y
    echo
    read -s -p "Please enter the final LUKS passphrase: " FINAL_PASSPHRASE
    echo
    read -s -p "Please confirm the final LUKS passphrase: " CONFIRMED_PASSPHRASE
    echo
    if [ "$FINAL_PASSPHRASE" != "$CONFIRMED_PASSPHRASE" ]; then
        echo "Passphrases do not match. Exiting."
        return
    fi
    cat /etc/cryptsetup-keys.d/luks_password.txt | cryptsetup luksRemoveKey /dev/nvme0n1p5
    printf "%s" "$FINAL_PASSPHRASE" | cryptsetup luksAddKey /dev/nvme0n1p5 --key-file /etc/cryptsetup-keys.d/dm_crypt-0.key
    cryptsetup luksRemoveKey /dev/nvme0n1p5 --key-file /etc/cryptsetup-keys.d/dm_crypt-0.key
    printf "%s" "$FINAL_PASSPHRASE" | clevis luks bind -k - -d /dev/nvme0n1p5 tpm2 '{"pcr_bank":"sha256"}'
    echo "dm_crypt-0 UUID=$(blkid -s UUID -o value /dev/nvme0n1p5) none luks" | tee /etc/crypttab
    echo "TPM sealed LUKS keyslot has been configured."
    echo "cleaning"
    rm -dfr /etc/cryptsetup-keys.d
    update-initramfs -u
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
    GRUB_HASH=$(echo -e "$GRUB_PASSWORD\n$GRUB_PASSWORD" | grub-mkpasswd-pbkdf2 | tail -n 1 | awk '{print $NF}')
    unset GRUB_PASSWORD
    cat ./helpers/40_custom | while IFS= read -r line; do eval echo "$line"; done >> /etc/grub.d/40_custom
    # make that password required for any menuentry other than normal boot
    sed -i 's/echo "menuentry '\''\$(echo "\$os" | grub_quote)'\'' \(${CLASS}\)/echo "menuentry '\''\$(echo "\$os" | grub_quote)'\'' --unrestricted \(${CLASS}\)/' /etc/grub.d/10_linux
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
        SSHD_CONFIG="/etc/ssh/sshd_config"
        MATCH_LINE="Match User user"

        # Case 1: block doesn't exist -> append complete block
        if ! grep -q "^$MATCH_LINE" "$SSHD_CONFIG"; then
            printf "\nMatch User user\n   AuthenticationMethods publickey\n" | tee -a "$SSHD_CONFIG"
        else
            # Case 2/3: block exists -> check if it already contains the AuthenticationMethods line
            if awk '
                BEGIN { in=0; found=0 }
                /^Match[[:space:]]+User[[:space:]]+user[[:space:]]*$/ { in=1; next }
                in && /^[[:space:]]*AuthenticationMethods[[:space:]]+publickey[[:space:]]*$/ { found=1 }
                in && /^Match[[:space:]]/ { in=0 }
                END { if(found) exit 0; else exit 1 }
            ' "$SSHD_CONFIG"; then
                # Case 3: AuthenticationMethods publickey already present - do nothing
                :
            else
                # Case 2: insert AuthenticationMethods publickey into the existing Match block
                tmpfile=$(mktemp)
                awk -v ind="   " -v al="AuthenticationMethods publickey" '
                    BEGIN { in=0; printed=0 }
                    /^Match[[:space:]]+User[[:space:]]+user[[:space:]]*$/ { print; in=1; printed=0; next }
                    in && /^[[:space:]]*AuthenticationMethods[[:space:]]+publickey[[:space:]]*$/ { printed=1 }
                    in && /^Match[[:space:]]/ {
                        if (!printed) print ind al
                        in=0
                    }
                    { print }
                    END { if (in && !printed) print ind al }
                ' "$SSHD_CONFIG" > "$tmpfile" && mv "$tmpfile" "$SSHD_CONFIG"
            fi
        fi
        systemctl restart ssh
    fi
}

do_luks
do_grub
do_tty1
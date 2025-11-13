#!/bin/bash
read -r -s -p "set GRUB password: " GRUB_PASSWORD
systemctl mask getty@tty1.service
sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="intel_iommu=on"/' /etc/default/grub
GRUB_HASH=$(echo "$GRUB_PASSWORD" | grub-mkpasswd-pbkdf2 | tail -n 1 | awk '{print $NF}')
unset GRUB_PASSWORD
CONFIG_LINES=$(cat <<-EOF
set superusers="admin"
password_pbkdf2 admin ${GRUB_HASH}
EOF
)
printf '%s\n' "$CONFIG_LINES" | sed -i '1i\
    set superusers="admin"\
    password_pbkdf2 '"admin"' '"${GRUB_HASH}"'' "/etc/grub.d/40_custom"
sed -i 's/echo "menuentry '\''\$(echo "\$os" | grub_quote)'\'' \$\{CLASS\}/echo "menuentry '\''\$(echo "\$os" | grub_quote)'\'' --unrestricted \$\{CLASS\}/' /etc/grub.d/10_linux
update-grub
sed -i 's|^#\?\(PasswordAuthentication\s\+\)\(yes\|no\).*$|\1no|; s|^#\?\(KbdInteractiveAuthentication\s\+\)\(yes\|no\).*$|\1no|' /etc/ssh/sshd_config
printf "\nMatch User user\n    AuthenticationMethods publickey\n" | tee -a /etc/ssh/sshd_config
# denied from tty1 console login.
echo "user" | tee /etc/denied_console_users
chmod 644 /etc/denied_console_users
sed -i '/#auth required/a auth required pam_listfile.so item=user sense=deny file=\/etc\/denied_console_users onerr=succeed' /etc/pam.d/login
systemctl restart sshd
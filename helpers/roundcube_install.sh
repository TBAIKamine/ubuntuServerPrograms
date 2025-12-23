#!/bin/bash
apt install php-mbstring php-intl php-xml -y
wget -O /var/www/mail.tar.gz https://github.com/roundcube/roundcubemail/releases/download/1.6.11/roundcubemail-1.6.11-complete.tar.gz
tar -xf /var/www/mail.tar.gz --directory /var/www
mv /var/www/roundcube* /var/www/mail
rm /var/www/mail.tar.gz
mkdir -p /var/www/mail/db
sqlite3 /var/www/mail/db/mainDatabase.sqlite3 < /var/www/mail/SQL/sqlite.initial.sql
chown -R www-data /var/www/mail/db/mainDatabase.sqlite3
if [ ! -f /var/www/mail/config/config.inc.php ]; then
	cp /var/www/mail/config/config.inc.php.sample /var/www/mail/config/config.inc.php
fi
RC_CONFIG_FILE="/var/www/mail/config/config.inc.php"
sed -i "s|^\$config\['db_dsnw'\].*|\$config['db_dsnw'] = 'sqlite:////var/www/mail/db/mainDatabase.sqlite3';|" "$RC_CONFIG_FILE"
sed -i "s|^\$config\['imap_host'\].*|\$config['imap_host'] = array('ssl://%n:993');|" "$RC_CONFIG_FILE"
sed -i "s|^\$config\['smtp_host'\].*|\$config['smtp_host'] = 'tls://%n:587';|" "$RC_CONFIG_FILE"
DES_KEY=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24)
sed -i "s|^\$config\['des_key'\].*|\$config['des_key'] = '$DES_KEY';|" "$RC_CONFIG_FILE"
if grep -q "^\$config\['smtp_user'\]" "$RC_CONFIG_FILE"; then
  sed -i "s|^\$config\['username_domain'\].*|\$config['username_domain'] = '%t';|" "$RC_CONFIG_FILE"
else
  echo "\$config['username_domain'] = '%t';" >> "$RC_CONFIG_FILE"
fi
if grep -q "^\$config\['username_domain_forced'\]" "$RC_CONFIG_FILE"; then
  sed -i "s|^\$config\['username_domain_forced'\].*|\$config['username_domain_forced'] = true;|" "$RC_CONFIG_FILE"
else
  echo "\$config['username_domain_forced'] = true;" >> "$RC_CONFIG_FILE"
fi
if [ -n "$FQDN" ]; then
	sudo a2sitemgr -d "mail.*" --mode swc
fi
if [ -f /etc/apache2/sites-available/mail.conf ]; then
  sudo a2ensite mail.conf
fi
systemctl restart apache2
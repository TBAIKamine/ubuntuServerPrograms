#!/bin/bash
if [ -f /tmp/docker-mailserver/sni_cert_map ]; then
    postmap /tmp/docker-mailserver/sni_cert_map
fi
if [ -f /tmp/docker-mailserver/99-sni.conf ]; then
    cp /tmp/docker-mailserver/99-sni.conf /etc/dovecot/conf.d/99-sni.conf
fi
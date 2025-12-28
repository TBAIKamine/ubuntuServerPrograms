#!/bin/bash

# get tokens
gitea_tokens.sh

#install kvm

#inject runner docker install
apt update -y
apt upgrade -y
apt install -y docker.io docker-compose-v2
    #pass the compose and .env files


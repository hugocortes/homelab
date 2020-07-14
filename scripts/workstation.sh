#!/bin/sh

echo "running setup..."

GITHUB_DIR=~/code/github.com/hugocortes/homelab
if [ ! -d $GITHUB_DIR ]; then
  echo "fetching github repository"
  mkdir -p ~/code/github.com/hugocortes
  git clone https://github.com/hugocortes/homelab.git $GITHUB_DIR
fi

if [ -f /etc/lsb-release ]; then
  sudo apt-get update -y
  sudo apt-get upgrade -y
  sudo apt install ansible -y
fi

cd $GITHUB_DIR
if [ ! -f inventory/group_vars/all/all.yaml ]; then
  scp inventory/group_vars/all/all.yaml.example inventory/group_vars/all/all.yaml
fi
if [ ! -f inventory/group_vars/all/kubespray.yml ]; then
  scp inventory/group_vars/all/kubespray.yml.example inventory/group_vars/all/kubespray.yml
fi
if [ ! -f inventory/hosts.ini ]; then
  scp inventory/hosts.example.ini inventory/hosts.ini
fi
if [ ! -f inventory/localhost.ini ]; then
  scp inventory/localhost.example.ini inventory/localhost.ini
fi

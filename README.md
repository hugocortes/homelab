# homelab
Homelab Terraform and Ansible playbooks

# Running

## Raspberry Pi

[rpi-default.yaml](playbooks/rpi-default.yaml) will add a user, add ssh keys, and change the default raspberry pi password to provide more security. Create `vars.yaml` by doing: `cp vars.example.yaml vars.yaml` and entering your data.

Running:
```sh
ansible-playbook --ask-pass -i inventory/hosts.ini playbooks/rpi-default.yaml
```

## All Hosts

[initialize.yaml](playbooks/initialize.yaml) will set the host with a hostname (retrieved from host.ini), updates all pacakges, and runs through security roles which include: disabling SSH password auth, installing unattended upgrades, and installing fail2ban.

Running:
```sh
ansible-playbook -i inventory/hosts.ini playbooks/initialize.yaml
```

`update` role is provide a flag as a way to just update all hosts with latest package.

Running:
```sh
ansible-playbook -i inventory/hosts.ini --tags update playbooks/initialize.yaml
```

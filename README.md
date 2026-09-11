# homelab

Ansible for three CentOS Stream 9 hosts.

| host | runs |
|---|---|
| `ipa-0` | FreeIPA, Keycloak, Pomerium, Postgres |
| `media` | Plex, Gramps, Miniflux, Ombi, Calibre-Web, Tautulli |
| `pirate` | Sonarr, Radarr, Jackett, SABnzbd, Transmission, Calibre |

`ops` is down; its entry in `inventory/hosts.yml` is commented out with
instructions for bringing it back.

## Setup

Secrets are encrypted with `ansible-vault`. The passphrase lives in the macOS
Keychain and is read by `bin/vault-pass.sh`, wired in through `ansible.cfg`.
On a new control node:

```sh
security add-generic-password -a "$USER" -s ansible-vault-homelab -w '<passphrase>'
git submodule update --init          # ansible-freeipa
ansible-galaxy collection install -r requirements.yml
```

## Running

```sh
# routine maintenance: upgrade packages, reboot only if the OS says to
ansible-playbook playbooks/base.yml --tags update

# converge without upgrading
ansible-playbook playbooks/base.yml

# reclaim disk: rotate logs, prune unused docker images
ansible-playbook playbooks/base.yml --tags prune

# everything
ansible-playbook playbooks/site.yml
```

Per-host playbooks — `media.yml`, `pirate.yml`, `docker.yml`, `auth.yml`,
`acme.yml`, `ipa.yml` — are runnable on their own; each imports
`bootstrap.yml`, which establishes the facts the roles depend on.

`--check` is meaningful here. Use it.

## Layout

```
playbooks/     site, bootstrap, base, and one per host class
roles/         flat; no nested paths
inventory/
  hosts.yml
  group_vars/*/main.yml    plaintext structure
  group_vars/*/vault.yml   ansible-vault encrypted
bin/vault-pass.sh
requirements.yml
```

`playbooks/ipa.yml` gates everything that mutates the FreeIPA directory behind
`-e freeipa_install_server=true` / `-e freeipa_configure=true`. Read the header
before passing either.

## Linting

```sh
ansible-lint
```

Exits 0. Everything skipped in `.ansible-lint` is a deliberate convention with
a comment saying why — a new finding is a real regression, not backlog.

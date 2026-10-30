# kitchenriff

KitchenRiff on `media`, as two containers from private GHCR images. What the
images need is specified by `../kitchenriff/docs/deployment.md`; this role is
where they run.

| container         | image                                | listens | published         |
| ----------------- | ------------------------------------ | ------- | ----------------- |
| `kitchenriff-web` | `ghcr.io/hugocortes/kitchenriff-web` | 8080    | `5180` on media   |
| `kitchenriff-api` | `ghcr.io/hugocortes/kitchenriff-api` | 3000    | no, alias `api`   |

Both sit on the `kitchenriff` network, pinned to `172.30.0.0/24` so the api's
`TRUST_PROXY` keeps matching web's address. api is also on `postgres`, where it
reaches the database as `postgres:5432`, the same way Miniflux and Gramps do.

pfSense/Cloudflare send `app.kitchenriff.com` to `media:5180`.

## Variables

| variable                          | where                     |
| --------------------------------- | ------------------------- |
| `kitchenriff_image_tag`           | `group_vars/all/main.yml` |
| `postgresql_kitchenriff_*`        | `group_vars/all/main.yml` |
| `ghcr_username`                   | `group_vars/all/main.yml` |
| `vault_ghcr_read_token`           | `group_vars/all/vault.yml` (classic PAT, `read:packages` only) |
| `vault_postgresql_kitchenriff_password` | `group_vars/all/vault.yml` |
| `vault_kitchenriff_blob_access_key_id`, `vault_kitchenriff_blob_secret_access_key` | `group_vars/all/vault.yml` (the R2 token for the `kitchenriff` bucket) |

Everything else (subnet, port, api env) is in `defaults/main.yml`.

## Deploying

Set `kitchenriff_image_tag` to the full SHA, then:

```sh
ansible-playbook playbooks/media.yml --tags kitchenriff
```

In order, and stopping at the first failure:

1. If the running api is not already on the new tag, run
   `node dist/app/migrate.js` once in a throwaway container of the **new** api
   image. Non-zero exit stops the play; the old containers keep serving.
2. Recreate api, wait for its healthcheck (`/health/ready`, which needs the
   database), then recreate web.
3. Through web on `:5180`: `/healthz` is 200, `/api/v1/me` is 401
   `application/problem+json`, and the api can fetch the issuer's
   `/.well-known/openid-configuration`. If only that last one fails, it is DNS
   or hairpin NAT on the home network, not the containers.

## Rolling back

Set `kitchenriff_image_tag` to the previous SHA and skip the migration:

```sh
ansible-playbook playbooks/media.yml --tags kitchenriff -e kitchenriff_migrate=false
```

Every migration works with the image before it, so the schema can stay put.

## Operator scripts

They need the api's env plus `PUBLIC_ORIGIN`, which the running api container
already has:

```sh
# one app invite link, valid 7 days
sudo docker exec kitchenriff-api node dist/app/scripts/invite-app.js

# who may start kitchens
sudo docker exec kitchenriff-api node dist/app/scripts/set-app-invite-limit.js --user <id> --limit <n|unlimited>
```

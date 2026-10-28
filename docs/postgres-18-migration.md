# Postgres 15 → 18

Both postgres instances move from `public.ecr.aws/bitnami/postgresql:15.8.0`
to the official `postgres:18.6-trixie`, by dump and restore. A major version
cannot open an older data directory, and the two images disagree on uid
(1001 vs 999) and layout, so `pg_upgrade` buys nothing at this size.

| host | databases | size | stop first |
|---|---|---|---|
| media | miniflux, gramps_cortes, gramps_user, kitchenriff | ~136 MB | `miniflux gramps`, and the kitchenriff app off-host |
| ipa-0 | keycloak | ~39 MB | `keycloak` (every pomerium login fails until it is back) |

Do media first. It can have a bad day; ipa-0 is the login for everything.

## Before starting

**The bitnami image can no longer be pulled.** `public.ecr.aws/bitnami/postgresql`
is gone from the registry; each host has 15.8.0 only in its local cache. The
rollback below works because the old container is kept, stopped, and a stopped
container pins its image. Until the migration is done and accepted:

- do not `docker rm postgres-15`
- do not run `--tags prune` on that host
- do not revert the role and rerun ansible as a way back — that would try to
  pull an image that no longer exists

The old data directory, `/opt/postgres`, is left untouched by everything
here. The new one is `/opt/postgresql`.

What was checked on both hosts before writing this, so the restore has no
surprises: every database is UTF8 / `en_US.UTF-8` (present in the official
image); the only extensions are `plpgsql` and `hstore` (contrib, shipped);
bitnami preloads `pgaudit` but no database has it installed; every password
is already SCRAM. The whole procedure was rehearsed against
`bitnamilegacy/postgresql:15.8.0` (the same image, republished): the restore
logs exactly one error, `role "postgres" already exists`, and app roles log
in over TCP with their old passwords.

## Migrate one host

Pull the new images first so the downtime is only the dump and restore. On
the host, as root (`sudo -i`):

```sh
docker pull postgres:18.6-trixie
docker pull quay.io/prometheuscommunity/postgres-exporter:v0.20.1
```

**1. Stop everything that writes.** An app restarting against the new, empty
database would create a fresh schema that the restore then collides with.

```sh
docker stop miniflux gramps        # media
docker stop keycloak               # ipa-0
```

**2. Dump with the 18 client.** `pg_dumpall` from the newer major is the
supported direction.

```sh
umask 077
docker run --rm --network postgres \
  -e PGPASSWORD="$(docker exec postgres printenv POSTGRES_PASSWORD)" \
  postgres:18.6-trixie pg_dumpall -h postgres -U postgres > /root/pg15-dumpall.sql
tail -3 /root/pg15-dumpall.sql     # must end with "PostgreSQL database cluster dump complete"
```

The dump contains every role's password hash. It stays 0600 under `/root`.

**3. Retire the old container, keeping it.**

```sh
docker stop postgresql-metrics postgres
docker rename postgres postgres-15
```

**4. Start 18 and nothing else.** From the control node:

```sh
ansible-playbook playbooks/media.yml --tags postgresql     # or playbooks/auth.yml
```

The tag runs only the postgresql role (plus the always-on bootstrap facts),
so the apps stay stopped. It creates `/opt/postgresql`, starts an empty 18
cluster in `/opt/postgresql/18/docker`, and replaces the exporter.

**5. Wait for initdb to finish, then restore.** `pg_isready` answers during
the entrypoint's temporary init server, which then restarts; wait for the log
line instead.

```sh
until docker logs postgres 2>&1 | grep -q 'init process complete'; do sleep 1; done
until docker exec postgres pg_isready -q; do sleep 1; done
docker exec -i postgres psql -U postgres -X -q < /root/pg15-dumpall.sql 2>&1 | grep -E 'ERROR|FATAL'
```

The only line it should print is `ERROR:  role "postgres" already exists`.
Anything else, stop and read it before going on.

**6. Rebuild planner statistics.** A dump carries no statistics, and the
first queries after a restore otherwise plan blind.

```sh
docker exec postgres vacuumdb -U postgres --all --analyze-in-stages
```

**7. Check it.**

```sh
docker exec postgres psql -U postgres -c '\l' -c '\du'
docker exec postgres psql -U postgres -tAc 'select version()'
```

Same databases and roles as before, on 18.6.

**8. Bring the apps back.** A full run starts the stopped containers.

```sh
ansible-playbook playbooks/media.yml     # or playbooks/auth.yml
```

Then: miniflux and gramps log in (media); keycloak finishes startup and a
pomerium route signs in (ipa-0); `postgresql-metrics` on :9187 reports
`pg_up 1`.

## Roll back

Only before anything you care about has been written to 18 — after that,
going back loses those writes.

```sh
docker stop postgres postgresql-metrics
docker rm postgres
docker rename postgres-15 postgres
docker start postgres
```

Then keep ansible's postgresql role off this host until it is fixed: the next
run would recreate 18 over the rollback. If neither host has migrated yet,
revert the commit that changed the role. If the other host is already on 18,
reverting would break that one instead, so just don't run this host's
playbook in the meantime. The exporter can stay on v0.20.1; it reads 15 fine.

## Clean up

After a week on 18 with nothing wrong:

```sh
docker rm -v postgres-15     # -v also drops bitnami's anonymous volumes
rm -rf /opt/postgres
rm /root/pg15-dumpall.sql
```

The bitnami image is then unreferenced and goes with the next `--tags prune`.

## Next major

The 18 image keeps its data in `/var/lib/postgresql/<major>/docker` and the
mount is `/var/lib/postgresql`, so 19 can be a `pg_upgrade --link` inside the
same mount instead of another dump and restore. That is the reason for the
layout; there is nothing to do about it until 19.

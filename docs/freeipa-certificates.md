# Certificates on ipa-0

FreeIPA here is **CA-less** (`enable_ra = False`, `ra_plugin = none`, no
Dogtag). The server certificate comes from Let's Encrypt over the Cloudflare
DNS-01 challenge; FreeIPA issues nothing itself.

Work splits in two. The frequent half is automated. The rare half is not, on
purpose.

| | how often | who does it |
|---|---|---|
| issue, publish, install into dirsrv | ~60 days | `certbot-renew.timer` + the deploy hook |
| teach IPA to trust a new Let's Encrypt chain | ~yearly, unpredictable | a human, using this document |

## What actually reads the certificate

Checked on the host, not assumed. Several things the old runbook updated turn
out to be read by nothing.

| consumer | reads | automated? |
|---|---|---|
| httpd `:443` | `/etc/ssl/<cn>/<cn>.fullchain.pem` + `.key`, via an **overridden** `ssl.conf` | yes — publish + reload |
| 389-ds `:636` | NSS database `/etc/dirsrv/slapd-IPA-HOMELABOPS-DEV/cert9.db` | yes — `ipa-server-certinstall -d` |
| `/var/lib/ipa/certs/httpd.crt` | nothing. Only `ssl.conf.rpmsave` names it | dead — do not maintain |
| `/opt/keycloak/x509/*` | mounted to `/etc/x509/https`, but holds root + intermediates with **no leaf and no key**; Keycloak publishes `7080->8080` plain HTTP | dead — do not maintain |
| `<cn>.pk12` | nothing outside `/etc/ssl` | dead — do not maintain |
| Pomerium | `insecure_server: true`, HTTP on `:8080`, `autocert: false` | never used these certs |

The stock FreeIPA `ssl.conf` points httpd at `/var/lib/ipa/certs/httpd.crt`.
This deployment replaced it with one that reads the published PEM directly.
That is why copying into `httpd.crt` and running `restorecon` — the first block
of the old runbook — changes nothing, and why the deploy hook does **not** pass
`--http` to `ipa-server-certinstall`.

If anyone ever restores the stock `ssl.conf`, that stops being true and
`certbot_ipa_dirsrv`'s sibling `--http` has to come back. Check `ssl.conf`
before assuming.

## The automated path

`playbooks/acme.yml` installs certbot, the Cloudflare DNS plugin, credentials,
and a deploy hook, then enables `certbot-renew.timer`. Running the playbook is
a **setup** step, not a renewal step; renewal happens on the timer thereafter,
inside the last 30 days of validity.

On each renewal the hook:

1. checks the new certificate and key are a matching pair, and refuses if not
2. publishes them to `/etc/ssl/<cn>/`
3. runs `ipa-server-certinstall -d`, which updates the NSS database and
   restarts dirsrv
4. waits for LDAPS to answer again, and fails loudly if it does not
5. reloads httpd

The Directory Manager password is piped in on **stdin** from
`/etc/letsencrypt/ipa-dirman` (mode 0600), never passed as `-p`, so it does not
appear in `ps`. `--pin=` is empty because certbot writes an unencrypted PEM
key; without it the command waits forever on a prompt nobody will answer.

Note that certbot mints a **new private key on every renewal**. The old flow
reused a single key dated 2021-05-21 for four years. This is why step 3 has to
run every time, not only when the chain changes.

## The manual path: Let's Encrypt rotated its chain

`ipa-server-certinstall` refuses a chain whose CA is not already trusted by
IPA. That refusal is the intended signal, and it is safe: it fails **before**
changing anything, leaving dirsrv on its previous certificate, which is still
valid for roughly 30 more days. There is time. Do not panic-force it.

Current trust, from `ipa-cacert-manage list`:

```
ROOT            ISRG Root X1
INTERMEDIATE    <Let's Encrypt intermediate, presently YR1>
INTERMEDIATE_2  <cross-signing root, presently Root YR>
R11 R12 R13     older intermediates, kept
```

When a renewal fails on an untrusted CA, extract the new chain and install it:

```sh
DOMAIN=ipa-0.homelabops.dev
cd /etc/ssl/$DOMAIN

# split the fullchain certbot just fetched; cert 1 is the leaf
awk 'BEGIN{n=0} /BEGIN CERT/{n++} {print > ("chain-" n ".pem")}' $DOMAIN.fullchain.pem
for f in chain-*.pem; do echo "== $f"; openssl x509 -noout -subject -issuer -in $f; done

# install whichever links are new, under names that are not already taken
ipa-cacert-manage install chain-2.pem -n INTERMEDIATE_3
ipa-cacert-manage install chain-3.pem -n ROOT_2

ipa-certupdate
```

Then re-run the deploy hook by hand rather than waiting for the timer:

```sh
RENEWED_LINEAGE=/etc/letsencrypt/live/ipa-0.homelabops.dev \
  /etc/letsencrypt/renewal-hooks/deploy/publish-and-reload.sh
```

Clients (`media`, `pirate`) pick up the new trust on their next `ipa-certupdate`.
If they do not, the files to look at are `/etc/ipa/ca.crt`,
`/var/lib/ipa-client/pki/ca-bundle.pem`,
`/var/lib/ipa-client/pki/kdc-ca-bundle.pem`, followed by
`update-ca-trust extract`.

## Break glass: the certificate already expired

If the certificate has **already expired**, `ipa-server-certinstall` cannot
run: it talks to the IPA API over HTTPS, and that connection now fails its own
validation —

```
cannot connect to 'https://ipa-0.homelabops.dev:443/acme/directory':
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed
```

Chicken and egg: installing a certificate requires a working certificate. Break
it by putting a valid certificate under httpd by hand first, then going back to
the normal path:

```sh
DOMAIN=ipa-0.homelabops.dev
cp /var/lib/ipa/certs/httpd.crt /var/lib/ipa/certs/httpd.crt.back
cp -f /etc/ssl/$DOMAIN/$DOMAIN.crt /var/lib/ipa/certs/httpd.crt
restorecon -v /var/lib/ipa/certs/httpd.crt
systemctl restart httpd && ipactl restart
```

This only works if `ssl.conf` is the **stock** one pointing at `httpd.crt`. With
the overridden `ssl.conf` in place, put a valid `fullchain.pem` and `.key` into
`/etc/ssl/$DOMAIN/` instead and restart httpd.

Letting it get this far means the renewal timer was failing for 30 days without
anyone noticing. Check `systemctl status certbot-renew.timer` and
`journalctl -u certbot-renew` before assuming it was bad luck.

## Sanity checks

```sh
# what is actually being served, by each consumer
echo Q | openssl s_client -connect ipa-0.homelabops.dev:443 -servername ipa-0.homelabops.dev 2>/dev/null | openssl x509 -noout -subject -issuer -enddate
echo Q | openssl s_client -connect ipa-0.homelabops.dev:636 -servername ipa-0.homelabops.dev 2>/dev/null | openssl x509 -noout -subject -issuer -enddate

# renewal machinery
certbot certificates
systemctl list-timers certbot-renew.timer

# a dry run that exercises issuance without spending rate limit
certbot renew --dry-run
```

The `:443` and `:636` certificates should match. If `:443` is newer, the
directory server install is failing and nobody noticed — that is the exact
failure this document exists for.

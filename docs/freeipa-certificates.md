# Certificates on ipa-0

FreeIPA here is **CA-less** (`enable_ra = False`, `ra_plugin = none`, no
Dogtag). The server certificate comes from Let's Encrypt over the Cloudflare
DNS-01 challenge; FreeIPA issues nothing itself.

Work splits in two. The frequent half is automated. The rare half is not, on
purpose.

| | how often | who does it |
|---|---|---|
| issue, publish, install into dirsrv | ~60 days | `certbot-renew.timer` + the deploy hook |
| trust a rotated Let's Encrypt **intermediate** | most renewals | the deploy hook, automatically |
| refresh the **clients'** CA bundles | whenever they fall behind | `roles/ipa_ca_trust`, from `base.yml` |
| accept a new **root** / trust anchor | ~never | a human, using this document |
| recover an expired certificate or a dead client anchor | ~never | a human, break-glass sections below |

> **Corrected 2026-09-11.** This document originally said chain rotation was a
> roughly yearly event. It is not. Let's Encrypt round-robins issuance across a
> pool of intermediates: two certificates requested forty minutes apart came
> back signed by `YR1` and then `YR2`. The `R11`/`R12`/`R13` entries already in
> the trust store are the same thing, installed by hand over previous years.
> Expect a new intermediate on most renewals, not on an annual schedule.

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

### Nicknames

NSS nicknames are labels only — trust is keyed on the certificate itself, so a
badly named entry is misleading, never broken. Two conventions are in use:

| nickname | actually holds | expires |
|---|---|---|
| `ROOT` | ISRG Root X1 — the only genuinely self-signed root here | 2035-06-04 |
| `INTERMEDIATE` | `YR1` | 2028-09-02 |
| `INTERMEDIATE_2` | `Root YR` — *not* a peer of `INTERMEDIATE`; it is what signs YR1/YR2 | 2032-09-02 |
| `R11` `R12` `R13` | themselves | 2027-03-12 |

The positional names (`INTERMEDIATE`, `INTERMEDIATE_2`) are the older mistake:
they record where a certificate sat in one particular chain rather than what it
is, and `INTERMEDIATE_2` is actively wrong about the hierarchy. **Name new
entries after the CA's CN**, as `R11`/`R12`/`R13` already do.

Renaming the existing ones means delete-then-reinstall — NSS has no rename —
and is pure cosmetics for a nonzero risk. Two rules if you ever do it: never
delete the intermediate that signed the certificate currently being served
(check with `openssl s_client ... :636`), and never delete an intermediate just
because it is not in use today, because the round-robin will hand it back.
`ipa-cacert-manage prune` only removes *expired* certificates; nothing here is
expired, so it is a no-op.

**For anyone automating this:** decide "is this CA already trusted?" by
certificate fingerprint, never by nickname. `YR1` is present under the nickname
`INTERMEDIATE`, so a nickname-based check would conclude it is missing and
collide on reinstall.

The deploy hook now does this by itself for **intermediates**: it compares the
chain it was handed against `/etc/ipa/ca.crt` by fingerprint, installs anything
missing under a nickname taken from the CA's CN, and runs `ipa-certupdate`. It
refuses, changing nothing, if the chain no longer terminates in a root IPA
already trusts — adding a link under a known anchor moves no trust boundary,
accepting a new anchor does.

So the steps below are for the case the hook deliberately will not handle: a
genuinely new **root**. Extract the chain and install what is missing:

```sh
DOMAIN=ipa-0.homelabops.dev
cd /etc/ssl/$DOMAIN

# split the fullchain certbot just fetched; cert 1 is the leaf
awk 'BEGIN{n=0} /BEGIN CERT/{n++} {print > ("chain-" n ".pem")}' $DOMAIN.fullchain.pem
for f in chain-*.pem; do echo "== $f"; openssl x509 -noout -subject -issuer -in $f; done

# install whichever links are new, under names that are not already taken
# name each after its own CN, e.g. YR2 / YR3 -- see Nicknames above
ipa-cacert-manage install chain-2.pem -n YR2

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

## Break glass: a client can no longer reach the server

`ipa-certupdate` fetches the CA set over HTTPS and validates that connection
against the very bundle it is about to repair. Once the last valid anchor in
`/etc/ipa/ca.crt` expires, the two deadlock:

```
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
unable to get local issuer certificate
```

Seen on media 2026-09-11: its bundle held DST Root CA X3 and R3 and nothing
else, both expired in 2021. Nothing had complained for four years, because
sssd reaches the directory over GSSAPI on 389 and never exercises
`ldap_tls_cacert`.

Seed one valid anchor from the host's own OS trust store, then let
`ipa-certupdate` do the real sync:

```sh
cd /tmp && rm -rf seed && mkdir seed && cd seed
awk 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("sys" c ".pem")}' /etc/pki/tls/certs/ca-bundle.crt
for g in sys*.pem; do
  openssl x509 -noout -subject -in $g 2>/dev/null | grep -q 'CN=ISRG Root X1' && cp $g isrg.pem
done

cp -a /etc/ipa/ca.crt /etc/ipa/ca.crt.bak-$(date +%F)
cat isrg.pem >> /etc/ipa/ca.crt      # OpenSSL looks the issuer up by subject;
                                     # the expired certs alongside are inert
ipa-certupdate
```

`ISRG Root X1` is the anchor for the current chain. Confirm before trusting
that: `openssl s_client -connect <server>:443 -showcerts` and look at the
issuer of the topmost certificate returned.

`roles/ipa_ca_trust` exists to stop bundles reaching this state — it compares
each client's fingerprints against the server's on every converge and runs
`ipa-certupdate` when one is behind, while it still can.

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

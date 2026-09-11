# Vendored role

Copied from [bendews/ansible-letsencrypt-cloudflare][upstream] at commit
`186ba7d` ("Merge pull request #5 from SirAmikVase/patch-1").

It was a git submodule until it carried uncommitted local modifications that
could not be pushed anywhere. Vendoring puts those changes under version
control, where they can be reviewed, without forking upstream.

## Local changes against `186ba7d`

Three functional fixes, plus a quote-style reformat from an editor autoformatter
that touched most of `tasks/main.yml`:

| change | why |
|---|---|
| intermediate URL `lets-encrypt-r3-cross-signed.pem` → `gen-y/int-yr1.pem` | R3 is the retired issuing intermediate. The old URL still serves (HTTP 200) but is not what current certificates chain to. |
| `delay: 10` → `delay: 60` | DNS-01 validation was being attempted before the Cloudflare TXT record had propagated. |
| added `wait_for: timeout: 30` | same propagation problem. |

## Status

Excluded from `ansible-lint` as vendored code, consistent with how the
submodules were treated. This whole flow is slated for replacement — see
**AI-73**, which would retire this role entirely in favour of an ACME client
with a renewal timer on each host.

`tests/` and `.travis.yml` were not vendored; they test upstream's CI, not this
repo.

[upstream]: https://github.com/bendews/ansible-letsencrypt-cloudflare

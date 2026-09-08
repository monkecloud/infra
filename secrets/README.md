# Encrypted secrets

Every file here is SOPS-encrypted to the age key whose public half is in `/.sops.yaml`.
The private half lives in the cluster (Secret `sops-age` in `flux-system`) and in a
password manager. **Lose it and these files are noise.**

Only values are encrypted — names, namespaces and structure stay readable, so these
remain diffable.

## Why these are NOT under clusters/tamarin/

Flux does not reconcile this directory, deliberately. A secret belongs next to the
manifest that consumes it, and those manifests still live in Terraform (`20-platform`,
`30-workloads`) rather than in Flux. Applying secrets on their own would gain nothing,
and two of them are currently owned by operators that would fight over them:

- `postgres--pg-app` is generated and managed by CloudNativePG.
- `cert-manager--letsencrypt-prod-account-key` is managed by cert-manager.

As each workload moves into Flux, its secret moves into the reconciled tree beside it.
Until then this directory is a **recovery vault**: enough to rebuild, not yet live.

## Why these specific secrets

They are the ones a rebuild cannot regenerate correctly, because restored data or an
external service has already seen them:

- Tenant `*-pg` / `*-garage`, and `pg-app` — restored Postgres carries these
  passwords inside it; regenerating would lock you out of your own data.
- `letsencrypt-prod-account-key` — keeps your ACME account identity across rebuilds.

Site TLS certificates are deliberately **not** kept. Sites live in their own repos; when one
lands, cert-manager issues its certificate from the Ingress in that repo. Nothing at this
level needs to know which domains exist.

Operator PKI (`cnpg-ca`, `*-webhook-cert`, `pg-server`, `pg-replication`,
`metallb-memberlist`, `k3s-serving`, node passwords) is deliberately absent — it
regenerates itself and nothing outside a fresh cluster has seen it.

## Working with them

    sops secrets/<file>              # edit in place, re-encrypts on save
    sops --decrypt secrets/<file>    # read only

Garage keys restore with their original IDs via `garage key import <key-id> <secret-key>`,
which is what keeps restored objects readable.

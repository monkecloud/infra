# Apps

One namespace per app **per environment**: `<owner>-<app>-<env>`, e.g. `yarn-blog-prod`
and `yarn-blog-dev`. The owner prefix is there because Postgres roles and Garage buckets
are cluster-global, and because `kubectl get ns` should say whose app something is.

An environment is a namespace, not a variant inside one, so dev and prod run **identical
manifests** — no name suffixes, no label gymnastics, no shared quota, and dev cannot reach
prod's cache or database because egress is default-deny per namespace.

## Layout

| Path | What |
|---|---|
| `base/` | namespace + PSA labels, the `deployer` SA, its Role and binding, ResourceQuota, LimitRange, both NetworkPolicies |
| `_owners/<person>/` | that person's shared credentials — their Postgres role and Garage key |
| `<owner>-<app>-<env>/` | one overlay per app-environment |
| `kustomization.yaml` | the list of overlays that are actually live |

`base/` and `_owners/` are never applied on their own: Flux picks up every directory under
`clusters/tamarin`, so `kustomization.yaml` here lists the overlays explicitly and stops
the recursive scan at this directory. **An overlay is not live until it is in that list.**

## Adding an app environment

Create `clusters/tamarin/apps/<owner>-<app>-<env>/` with two files.

`kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: yarn-blog-prod        # this is what names the namespace
resources:
  - ../base
  - ../_owners/yarn              # the owner's pg + garage credentials
  - flux.yaml
```

`flux.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: app
spec:
  interval: 1m
  url: https://github.com/monkecloud/blog
  ref:
    branch: main                 # dev's overlay points at the dev branch instead
  # Private repo only: a deploy key or read-only PAT in this namespace.
  # secretRef:
  #   name: git-auth
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app
spec:
  interval: 5m
  path: ./k8s
  prune: true
  wait: true                     # a bad manifest fails loudly instead of half-applying
  timeout: 3m
  sourceRef:
    kind: GitRepository
    name: app
  serviceAccountName: deployer   # apply as the app, never as Flux
```

Then add the directory to `kustomization.yaml` here, and push.

## Why the Kustomization lives in the app's namespace

kustomize-controller impersonates `system:serviceaccount:<the Kustomization's own
namespace>:<serviceAccountName>`. A Kustomization parked in `flux-system` naming an SA
from somewhere else resolves to an account that does not exist and fails `Forbidden` on
every reconcile — verified against this cluster, the error names
`system:serviceaccount:flux-system:<sa>`.

So source, Kustomization and ServiceAccount all live together in the app's namespace, and
the `deployer` Role is the deploy boundary: an app repo is untrusted input, and Flux can
only apply what that Role already allows.

## What an app gets

- Its own namespace, quota and network policy.
- The owner's Postgres credentials as Secret `<owner>-pg` and Garage credentials as
  `<owner>-garage`. Prod uses the `uri` key, dev uses `uri_dev`.
- Nothing else. A cache is the app repo's own business — see
  `templates/app-repo/k8s/redis.yaml`.

Apps that outgrow the shared database or bucket can have their own without a new
credential: a CNPG `Database` CR owned by the same role, or
`garage bucket allow --read --write <bucket> --key <owner>-data-key`.

## Secrets

An app repo never carries credentials. Secrets are applied here, by the `flux-system`
Kustomization, which is the only one holding the SOPS age key. That also means a friend's
repo cannot contain a secret it could leak — there is nothing in it to leak.

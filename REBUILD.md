# Rebuilding the Tamarin cluster

From bare machines to a working cluster. Written for the case where everything is gone and
you are reading this under pressure.

**What you need to have kept:**

1. This repo.
2. The **age private key** (`AGE-SECRET-KEY-1...`) from your password manager. Nothing here
   decrypts without it.
3. Backups of Postgres and Garage, if you want the data back.

**What is NOT automatic.** Terraform builds VMs; Flux builds Kubernetes. Between and after
them are five manual steps. Miss them and the cluster comes up looking healthy but Garage
serves nothing and tenants have no database. They are marked ⚠ below.

---

## 0. Prerequisites

A working XCP-ng pool, and a VM template to clone. `tamarin-k3s-base` ships k3s
pre-installed, but it is **not required** — cloud-init installs the pinned k3s version on
first boot if the image lacks it, so a stock Ubuntu 24.04 cloud image works. Set
`template_name` accordingly.

Outside the cluster, and needed before certificates will issue:

- Router forwards **80 and 443 → `192.168.2.200`** (the ingress VIP, not a node address).
- DNS/DDNS for each domain points at the house's public IP.
- DHCP pool stays `.10-.99`, so it cannot hand out a VIP or a node address.

On the workstation: `terraform`, `kubectl`, `flux`, `age`, `sops`, `gh`.

## 1. VMs and k3s

```bash
cd terraform/10-vms
cp terraform.tfvars.example terraform.tfvars    # XO credentials, SR UUIDs
terraform init && terraform apply
export KUBECONFIG=$PWD/../kubeconfig
kubectl get nodes                                # expect 4 Ready
```

SR UUIDs are pool-specific and do not survive a pool rebuild. Re-read them:

```bash
ssh root@<pool-master> "xe sr-list type=ext params=uuid,name-label,host"
```

## 2. The age key

```bash
kubectl create namespace flux-system
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=/path/to/keys.txt
```

Flux needs this **before** it reconciles, or every encrypted secret fails to decrypt.

## 3. Flux

```bash
export GITHUB_TOKEN=$(gh auth token)
flux bootstrap github --owner=monkecloud --repository=infra \
  --path=clusters/tamarin --private=true \
  --components=source-controller,kustomize-controller
```

Only two controllers. helm-controller is deliberately absent — k3s has its own Helm engine
and the operators here are k3s `HelmChart` CRs.

Watch it build:

```bash
flux get kustomizations --watch
```

Expect `flux-system`, `platform`, `platform-config`, `workloads` to go Ready in that order.
`platform-config` waits on `platform` by design (its CRDs come from the operators).

> **If a new GitHub org rejects the deploy key** with `422 Deploy keys are disabled for this
> repository` — that is an org policy, not a repo problem:
> `gh api -X PATCH /orgs/monkecloud -f deploy_keys_enabled_for_repositories=true`, then
> re-run bootstrap. It is idempotent.

## 4. ⚠ Point kubeconfig at the API VIP

```bash
cd terraform && ./scripts/point-kubeconfig-at-vip.sh
```

Layer 10 fetched a kubeconfig aimed at the init node, because nothing answered on the VIP
that early. Without this you have no API HA — losing that one node loses `kubectl`. The
script verifies the VIP with certificate verification **on** before overwriting, which is
what catches a missing `tls-san`.

## 5. ⚠ Garage layout

```bash
./scripts/garage-layout.sh
```

**Garage is inert until it has a layout.** Its nodes find each other but hold no data
ranges, so every S3 call fails while the pods look perfectly healthy. This is the single
easiest step to miss.

## 6. ⚠ Garage buckets and keys

```bash
./scripts/garage-bucket.sh    # once per bucket
```

Needed: `yarn-data`, `cubesnail-data`, `registry`, and any project buckets.

Restoring instead of starting fresh? **Do not let this generate new keys.** Restored objects
are owned by the original key IDs. Import the committed ones:

```bash
kubectl exec -n garage garage-0 -- /garage key import <key-id> <secret-key> --yes
```

Key IDs and secrets are in this repo under `clusters/tamarin/workloads/tenants/` and
`registry/`. Decrypt with `sops --decrypt <file>`.

## 7. ⚠ Postgres roles and databases

```bash
../scripts/pg-tenant.sh <tenant> <password>     # once per tenant
```

Use the **committed** password from `clusters/tamarin/workloads/tenants/<tenant>--<tenant>-pg.sops.yaml`,
not a new one — restored Postgres data carries the old password hashes inside it.

This also does the `REVOKE CONNECT ON DATABASE ... FROM PUBLIC` that makes tenant isolation
real. Without it any role can connect to any database.

## 8. Restore data

Postgres via CNPG `spec.bootstrap.recovery` against the backup object store; Garage objects
by syncing them back into the buckets from step 6.

## 9. Sites

Each project repo carries its own `k8s/`. Add its `GitRepository` + `Kustomization` under
`clusters/tamarin/`, copying `templates/project-kustomization.example.yaml`. Certificates
issue themselves once DNS and the port-forwards are right.

---

## Verifying

```bash
kubectl get nodes                                   # 4 Ready
flux get kustomizations                             # all Ready
kubectl get cluster pg -n postgres                  # healthy, 3 instances
kubectl exec -n garage garage-0 -- /garage status   # 4 nodes, layout applied
kubectl get pods -A | grep -v Running               # only Completed
```

Tenant isolation is not verified by any of the above. Check it explicitly:

```bash
kubectl auth can-i --as=system:serviceaccount:yarn:yarn-user get nodes   # must be "no"
```

And confirm a tenant credential actually authenticates:

```bash
kubectl run pgcheck --rm -i --restart=Never -n yarn --image=postgres:18-alpine \
  --env PGPASSWORD="$(kubectl get secret yarn-pg -n yarn -o go-template='{{index .data "password"|base64decode}}')" \
  --command -- psql -h pg-rw.postgres.svc.cluster.local -U yarn -d yarn_dev \
  -tAc "select current_user"
```

## Testing this without a disaster

**Use the Let's Encrypt staging issuer.** Production allows 5 duplicate certificates per
domain per week; two rebuild drills will exhaust it for the real domains.

An untested rebuild is a hypothesis. The parts worth actually exercising are steps 2–7 —
the ones with no automation to catch a mistake.

## Known gaps

- `pg-tenant.sh`, `garage-layout.sh` and `garage-bucket.sh` have **no automatic caller**.
  They were invoked by Terraform layers that no longer exist. That is why they are ⚠ steps
  here rather than something that just happens.
- The `tamarin-k3s-base` template build is still a manual image process, documented in
  `../CLAUDE.md`. Cloud-init installing k3s makes it optional, not reproducible.
- Router port-forwards and DNS are outside all of this.

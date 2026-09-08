# Tamarin — VMs and cluster bootstrap

Builds the layer *below* Kubernetes: four VMs on the XCP-ng pool, cloud-inited into a k3s
cluster. Everything inside Kubernetes is Flux's job now and lives in
**`monkecloud/infra`** — see `../CLAUDE.md`, "Rebuild-from-git architecture".

| Path | What it does |
|---|---|
| `10-vms/` | Four VMs via Xen Orchestra, one pinned per physical host, each cloud-inited into a k3s server node. Fetches the admin kubeconfig. |
| `scripts/garage-layout.sh` | Assigns and applies Garage's cluster layout. |
| `scripts/garage-bucket.sh` | Creates a Garage bucket + a bucket-scoped key, writing the credentials into a Kubernetes Secret. |
| `scripts/point-kubeconfig-at-vip.sh` | Repoints the fetched kubeconfig at the API VIP once kube-vip is up. |

The two Garage scripts stay here rather than becoming Flux Jobs by explicit decision: they
are CLI-only operations against a running Garage, they already work and are idempotent, and
Terraform runs at rebuild time anyway. The cost is that nothing notices if a bucket
disappears later — accepted.

## Rebuild order

```bash
cd 10-vms
cp terraform.tfvars.example terraform.tfvars   # XO credentials
terraform init && terraform apply              # -> writes terraform/kubeconfig

# paste the age private key in, then bootstrap Flux
kubectl create secret generic sops-age -n flux-system --from-file=age.agekey=<key>
flux bootstrap github --owner=monkecloud --repository=infra \
  --path=clusters/tamarin --private=true \
  --components=source-controller,kustomize-controller
```

Flux then builds the platform and workloads on its own. Afterwards:

```bash
./scripts/garage-layout.sh                     # Garage is inert without a layout
./scripts/point-kubeconfig-at-vip.sh           # kubeconfig -> 192.168.2.201
```

**`point-kubeconfig-at-vip.sh` no longer has an automatic caller.** It used to run from
layer 20, which is gone. Run it by hand after Flux has brought kube-vip up. It verifies the
VIP answers *with certificate verification on* before overwriting, and restores the original
if it doesn't — which is what catches a missing `tls-san`.

## Not covered here

- **Data.** Postgres contents and Garage objects. Separate backups.
- **The XCP-ng pool** — installing XCP-ng, joining hosts, networking. Starts from a working pool.
- **Getting a base image into XCP-ng.** You need *some* template to clone, and importing one
  is outside Terraform. But it does not have to be a custom image: import the **official
  Ubuntu 24.04 cloud image** as a template and point `template_name` at it. Cloud-init
  installs the pinned k3s version plus open-iscsi and nfs-common on first boot.

  `tamarin-k3s-base` is the pre-baked variant in use today — k3s already installed, so it
  boots faster. It is otherwise equivalent. **Do not rebuild it if it is lost**; use a stock
  cloud image instead. Its original build is written up in `../CLAUDE.md` for reference only.
- **Router port-forwards (80/443) and DNS/DDNS.** Must be right *before* Flux applies the
  sites, or cert-manager's HTTP-01 challenges hang. Forward to the **ingress VIP
  `192.168.2.200`**, not a node address. The DHCP pool must stay `.10-.99` so it cannot hand
  out a VIP or a node address.

## Secrets

**Secrets now live encrypted in `monkecloud/infra`, not here.** SOPS + age; the private key
is in a password manager and in the cluster as `sops-age`. The rule is that any credential
restored data or an external service has already seen must be a *committed* value, never a
generated one — a rebuild that regenerates them produces a cluster that cannot read its own
restored data.

That reverses what this directory used to do. `k3s_token` and Garage's RPC secret are still
generated here, and that is still correct: nothing outside a fresh cluster has seen either.
Override them via variable when *adding* a node to a running cluster rather than rebuilding.

State, tfvars and the fetched kubeconfig are gitignored and hold plaintext credentials —
treat this directory the way `../CLAUDE.md` says to treat itself.

## Things that will bite

**Pool-specific UUIDs.** `10-vms/variables.tf` pins each node's SR by UUID because three of
the four hosts name their local SR "Local storage" — the label isn't unique pool-wide, so a
name lookup silently picks a random one. Those UUIDs survive a VM wipe but not a pool
rebuild:

```bash
ssh root@192.168.2.16 "xe sr-list type=ext params=uuid,name-label,host"
```

**Hosts aren't uniform.** tamarin-05 has ~4GiB more RAM than the other three, so `memory_max`
is per-node. Related trap: `xe host-list` over SSH returns *every* pool host, not the one you
connected to — filter by `uuid=` or you'll size a VM against the wrong host.

**`prevent_destroy` is set on the node VMs.** Destroying one drops an etcd member, including
as the destroy half of a replacement. Comment the `lifecycle` block out deliberately, do one
node, put it back. Rolling one at a time (cordon, drain, apply, uncordon) keeps quorum; two
at once does not.

**`tls-san` ordering cannot be worked around.** The API VIP is written by `10-vms` into each
node's `/etc/rancher/k3s/config.yaml` *before k3s first starts*. The apiserver serving
certificate is generated on first boot; adding a SAN later means regenerating it and
restarting k3s everywhere. If `10-vms`'s `api_vip` disagrees with the kube-vip manifest in
`monkecloud/infra`, kube-vip comes up and answers while every client rejects the certificate.

**The disk blocks are the one unverified part.** Everything else was checked against the
running cluster; this wasn't, because confirming it needs a real apply. `xenorchestra_vm` has
two `disk` blocks per node, assuming they map positionally onto the template's existing OS and
Longhorn disks rather than being created alongside them. If the first apply produces four
disks instead of two, drop the second block and attach the data disk separately. Check that on
one node before doing all four.

**Cloud-init ordering.** Joiner nodes wait for the init node's apiserver before enabling k3s.
k3s would retry anyway, but the explicit wait keeps a failed bootstrap visible in cloud-init's
log rather than buried in journalctl.

**Garage needs a layout before it does anything.** A fresh Garage cluster's nodes find each
other but hold no data ranges, so every S3 call fails until `layout assign` + `layout apply`
runs. `scripts/garage-layout.sh` places each node in a zone named after its k3s node, so
replicas land on different hypervisors. The `dxflrs/garage` image is distroless — no shell —
so admin commands are `kubectl exec -n garage garage-0 -- /garage <subcommand>`.

## Adding a node

When tamarin-01 comes back it needs a fresh `xe pool-join` first (its old pool identity was
forgotten). Then add an entry to the `nodes` map in `10-vms/terraform.tfvars` —
`192.168.2.105` is next free — and set `k3s_token` to the running cluster's token so it joins
rather than forming its own:

```bash
cd 10-vms && terraform output -raw k3s_token
```

`cluster_init` stays false; only one node ever has it.

## Status

`10-vms` describes the running cluster but has never been applied against it — there is no
state file. It is a rebuild path, not a live description. The useful periodic exercise is
reading it against reality to check the two haven't drifted.

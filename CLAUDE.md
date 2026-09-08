# Tamarin homelab — Xen Orchestra pool + planned k3s "mini cloud"

> **No credentials in this file.** It was scrubbed on 2026-09-08 so it could be committed to
> `monkecloud/infra` — it is the knowledge base a fresh session needs, and keeping it on one
> machine defeated the whole rebuild-from-git exercise.
>
> Credentials are in one of two places: **regenerated at install time** (XO login, the
> pool-wide host root password, the k3s join token, Garage's RPC secret), or **encrypted in
> this repo** under `secrets/` and `clusters/tamarin/workloads/`, readable with the age key.
> Keep it that way — do not paste a real password back into this file.

## What this is

A 5-host XCP-ng pool named **"Tamarin"** (hosts tamarin-01 through tamarin-05), managed via a local Xen Orchestra instance, being turned into a homelab "mini cloud" for shared services (Postgres, object storage, etc.) running on top of k3s.

## Hardware constraints (drives every design choice below)

- Each host: **4-core CPU**, **1Gbps Ethernet**
- This ruled out Ceph/Rook-Ceph (too resource/network hungry for these specs) in favor of lighter alternatives throughout.

## Current infrastructure state (as of 2026-08-29)

### Xen Orchestra access
- XO runs in a Docker container on this machine (`dt2`), reachable at `http://localhost:80`
- REST API: `http://localhost:80/rest/v0/...`, HTTP Basic Auth works directly
- Login: set when XO is installed. Real values are not in this repo — on a rebuild you choose them; for the running instance ask the user.
- **Container hardened 2026-09-07** — container name is now **`xo`** (was an auto-named `sweet_tharp`), with `--restart unless-stopped` and real bind mounts. Before this it had `RestartPolicy: no` and **zero volumes**, so XO's entire database lived in the container's writable layer: it had been dead since 2026-09-01 (exit 255, not OOM, no error recorded) and was one `docker rm` away from permanent loss of the pool registration, users and any backup config.
  - Host data now at **`/home/yarn/xo-data/`**: `xo-server/` → `/var/lib/xo-server` (leveldb + SDN controller certs), `redis/` → `/var/lib/redis`, `etc-xo-server/` → `/etc/xo-server`. Tiny (~10KB total).
  - **XO's real database is the redis instance running inside the container** (`redis://127.0.0.1:6379/0` per `config.toml`, `dump.rdb` in `/var/lib/redis`) — not leveldb, which only holds SDN controller certs. Backing up XO means backing up that RDB.
  - Migration method, if it ever needs redoing: `docker stop` first (clean shutdown flushes redis), then `docker cp` the three paths out, then recreate. Do **not** copy from a running container — leveldb compacts on startup and the copy goes stale immediately (hit this once; had to re-copy).
  - Old pre-migration container kept as stopped container **`xo-old`** as a rollback. Safe to `docker rm xo-old` once the new one has been trusted for a while.
  - Verified after migration: pool `Tamarin` still registered (master tamarin-03), 182 redis keys intact, `redis-cli SAVE` updates the host file's mtime (so writes really do land on the host), and state survives `docker restart`.
  - Note: this XO version's REST API has no `/rest/v0/remotes` or `/rest/v0/backup/jobs` endpoints (they're websocket-API only), so backup config can't be inspected over REST — use the web UI.
- No `sshpass`/`expect`/`paramiko` installed on this machine, and no passwordless sudo. Non-interactive SSH with password auth uses the `SSH_ASKPASS` trick:
  ```bash
  export SSH_ASKPASS=/path/to/askpass.sh   # a script that just echoes the password
  export SSH_ASKPASS_REQUIRE=force
  setsid ssh -o StrictHostKeyChecking=no root@<host> "command"
  ```
- Root SSH login for all tamarin hosts is `root` with the pool-wide password, which is set during XCP-ng install and is **not recorded here** — ask the user. Scripts read it from `NODE_ROOT_PASSWORD`; Terraform from the gitignored `root_password` tfvar.
- `~/.claude/settings.json` already has permission rules allowing `ssh`/`setsid ssh`/`timeout ssh` commands and an `autoMode.allow` entry covering SSH to `root@192.168.2.0/24` for this pool's recovery/setup work, so these commands shouldn't hit the auto-mode classifier block that came up repeatedly during initial recovery.

### Pool hosts
| Host | UUID | Address | Status |
|---|---|---|---|
| tamarin-02 | `0e9c340c-507c-47b4-a547-881388a82dee` | 192.168.2.33 | up, pool member |
| tamarin-03 | `302f12cc-8a6b-4052-b48e-1153ad2a2d71` | 192.168.2.16 | up, **pool master** |
| tamarin-04 | `341ac61b-f98e-4cc1-af26-eba00e0e7366` | 192.168.2.18 | up, pool member |
| tamarin-05 | `2c82c5ec-e289-4b2f-9320-e3c6a7e6985b` | 192.168.2.24 | up, pool member |
| tamarin-01 | `f0979810-16f3-4af5-8abe-41f9b5f2f9af` (old, now forgotten) | was 10.0.0.30 | **removed from pool** — see below |

### What happened (recovery history)
1. User's physical network got reconfigured, all hosts landed on new `192.168.2.0/24` DHCP addresses instead of old static `10.0.0.x` ones, breaking pool cohesion.
2. Diagnosed via XO REST API + direct XAPI (XML-RPC) queries + SSH, since XO itself couldn't see hosts at their new IPs.
3. tamarin-03 turned out to still be the pool master with intact metadata. Fixed the other 3 reachable slaves by rewriting `/etc/xensource/pool.conf` to `slave:192.168.2.16` and running `xe-toolstack-restart` (the `xe pool-emergency-reset-master` command hung indefinitely on this XCP-ng version — raw config edit + toolstack restart worked instead).
4. **tamarin-01 never came back** after a power-cycle — its switch port showed link up but zero Rx traffic ever (checked via switch port counters), pointing to a hung boot or a cable on the wrong physical NIC. User was going to physically check its console (no monitor readily available) and try again later.
5. Per user's instruction, tamarin-01 was **fully and permanently removed** from the pool: its 2 resident VMs (`work-tamarin-01`, `high-monke-monk-01`, both on host-local-only storage, non-shared) were destroyed, then the host itself was removed via `xe host-forget` (had to pipe `yes` to its confirmation prompt), then orphaned local SR records (`Local storage`, `Removable storage`, `DVD drives` for that host) were cleaned up via `xe sr-forget`. The pool's shared `XCP-ng Tools` SR was correctly left alone (it refused `sr-forget` since it's still attached elsewhere).
   - **If/when tamarin-01 comes back**, it will need to be re-added as a brand-new pool join (`xe pool-join` from that host), not reconnected — its old identity is gone from the pool DB.
6. Cleaned up 3 leftover custom VLAN networks (`IF01`/`IF02`/`IF03`, VLANs 1001/1002/1003 on eth0) that existed across all hosts — these had orphaned VIF records from already-deleted VM templates (`cloud-img-24`, `cloud-ubuntu-2404`, `ubuntu-cloud-img-2404`), no longer had real VMs on them. Removed via `xe vif-destroy` → `xe vlan-destroy` (12 VLAN objects, one per host per network) → `xe network-destroy`.
7. Result: **clean 4-host pool**. Only default networks remain (`pool-eth0` = management, `Host internal management network` = XCP-ng built-in). Only the 4 hosts' own control domains exist as VMs — no leftover templates, snapshots, or user VMs. Each host has its own near-empty default local-storage/DVD/removable SRs plus the shared `XCP-ng Tools` SR.

## Architecture decisions and rationale (built — kept for the reasoning)

### Orchestration: k3s
- Chosen over full k8s (kubeadm) — same API/operator ecosystem, much lighter control-plane footprint, better fit for 4-core hosts.
- Chosen over Nomad — Nomad is lighter still, but the operator ecosystem for HA Postgres is much thinner; since we need exactly that, k3s wins.
- **All nodes as k3s "server" nodes** (control-plane + workloads) rather than splitting off dedicated workers — at 5 nodes, the split isn't worth the complexity, and this gives etcd quorum across all 5 for free.

### Provisioning model
- One base VM template: OS (Ubuntu/Debian minimal) + k3s installed + `open-iscsi` + `nfs-common` (Longhorn prerequisites).
- One VM per physical tamarin host, cloned from that template — **make sure XO actually places one VM per physical host**, not two VMs stacked on the same hypervisor (this is a placement decision at VM-creation time, not something the image controls).
- Give each VM a **second virtual disk** (separate from the OS disk) for Longhorn to claim.
- First-boot k3s cluster join isn't baked into the static image (first node inits the cluster; others join with a shared token + that node's address) — handle via XO's cloud-init support at VM creation time.

### Storage: split strategy (important nuance, decided late in the conversation; reaffirmed 2026-09-07)
- **Longhorn** (k8s-native, much lighter than Ceph/Rook) — but only for workloads that *don't* do their own replication.
- **Postgres and Garage both already replicate themselves at the application layer** (Postgres streaming replication, Garage's own data distribution). Backing their volumes with Longhorn on top of that would double the replication (once at app layer, once at Longhorn's block layer) — wasted network/disk traffic on 1GbE links for no safety benefit.
  - **Decision: give Postgres/Garage local, non-replicated storage** via k3s's built-in `local-path-provisioner` (fast, no network hop), and let each app handle its own cross-node redundancy.
  - **Use Longhorn only for future workloads that don't have built-in replication of their own.**
- **Storage tiers, settled 2026-09-08.** The rule is now about *who owns the service*, not
  about individual workloads:
  - **Global services are the durable tier.** Anything that must survive is stored by a
    cluster-wide service that replicates itself across nodes — today **Postgres** and
    **Garage (S3)**. These are the only two things on the cluster that promise durability.
  - **Tenant workloads are stateless.** No PVC, not even Longhorn. If a tenant needs to keep
    something, it goes into Postgres or the bucket.
  - **Per-tenant Redis is explicitly best-effort.** It has a `local-path` PVC and appendonly
    on, so it survives a pod restart, but it is one pod on one node: unavailable while that
    node is down and *gone* if that node is lost. Not replicated, not backed up. It is a
    cache / lock / rate limiter / rebuildable queue, and the tenant docs say so in exactly
    those terms. The user's framing: "a 'hey sorry, I told you it wasn't persistent' kind of
    thing."
  - New durable needs get added as a **global** service (a future Kafka-like event store was
    floated), not by giving a tenant workload a volume.
  - Longhorn stays uninstalled. It only becomes justified for something stateful that has no
    replication of its own — and under this model that case should be rare, because durable
    things belong to global services that already replicate.

### Stateful services
- **Postgres**: CloudNativePG operator, 1 primary + 1-2 streaming replicas, local-path storage per replica.
- **Object storage**: **Garage** (Rust-based S3-compatible store, built specifically for small self-hosted clusters — lighter than MinIO's distributed mode or Ceph RGW), local-path storage per node, Garage's own replication across nodes.

### Redundancy philosophy (explicitly agreed with user)
- User is fine with a few minutes of downtime if a host needs a reboot for updates — **not** aiming for zero-downtime/instant-failover everywhere.
- Where continuous replication isn't worth the resource/network cost, lean on **XO's own VM backup/snapshot jobs** as the recovery mechanism instead (accept a short recovery window rather than paying for always-on replication).
- 1GbE is fine for normal app-level traffic (DB replication streams, cache invalidation, API calls) — the real pain point is *bulk* rebuild traffic (a Longhorn/Garage node rejoining after downtime moving many GB) which will visibly saturate 1GbE. Not a blocker, just don't expect fast bulk resyncs.

## Base VM template — built 2026-08-29

- Template name: **`tamarin-k3s-base`** (uuid `7aa3ae1d-2136-ba96-b163-7780cd53e25e`), tagged `k3s-base`, lives on tamarin-03's `local-storage` SR (uuid `3c2711f7-cd15-3216-f362-566a3c349c5d`).
- Contents: Ubuntu 24.04.4 LTS (official cloud image) + k3s v1.36.4+k3s1 installed but **not started/enabled** (`INSTALL_K3S_SKIP_START`/`INSTALL_K3S_SKIP_ENABLE`) + `open-iscsi` (iscsid enabled) + `nfs-common`. Root login enabled with the pool-wide password (set at install, not recorded here), `PermitRootLogin yes`.
- Two disks: OS disk (~20GiB, VDI uuid `fbb63726-ebc4-4eb5-a2d1-8d95f65d9b1f`) + a second empty 30GiB disk (VDI uuid `cdc985db-489e-4d8b-8b43-807b096aac53`, name "longhorn-data", unformatted) reserved for Longhorn. Both are full/thick-provisioned (import used `--prezeroed`), not thin — factor that into per-host storage headroom.
- **How it was built** (useful if rebuilding or debugging clones):
  1. Downloaded the official Ubuntu 24.04 cloud image on `dt2`, resized to 20G with `qemu-img`, converted to VHD (kept it sparse/small for transfer).
  2. Needed `xorriso`/`qemu-img` on `dt2` (installed via `sudo pacman -S --needed libisoburn qemu-img` — this machine has no sudo password on file, user ran it manually) — these weren't present anywhere (dt2 or dom0) beforehand.
  3. XCP-ng's `xe`-managed "iso" SR type (`xe sr-create type=iso ...`) is NFS-mount-oriented even with `legacy-mode=true` and fails locally (`xe-mount-iso-sr` script demands `-o` mount options) — don't bother with it for a simple local file. Instead, cloud-init's NoCloud seed was injected **directly into the guest filesystem** at `/var/lib/cloud/seed/nocloud/{user-data,meta-data}` by mounting the disk image via `qemu-nbd`/`kpartx` from dom0 before ever importing it into the SR — no ISO/CD needed at all.
  4. dom0's `qemu-img` (at `/usr/lib64/xen/bin/qemu-img`) only supports `raw`/`qcow2`/`vdi` — no `vpc` (VHD) driver — so conversions/mounting on dom0 must go through `qcow2`, converting to `raw` only as the last step right before `xe vdi-import format=raw`.
  5. **`xe vdi-import` needs the destination VDI's `virtual-size` to exactly match the source raw file's byte size** — `qemu-img resize`/format conversions can round the size up slightly (seen: 434176 bytes), and any mismatch fails with a misleading `VDI_IO_ERROR: Device I/O errors` (looks like an SR-space issue; it isn't — check `stat -c%s` on the source file first).
  6. Ubuntu 24.04's own cloud-init already generates a correct MAC-matched netplan for whatever the Xen NIC is actually named (`enX0` here, via systemd's Xen predictable-naming scheme) — don't fight this by hardcoding `eth0`, it's unnecessary and was a red herring during debugging.
  7. To edit files on a halted VM's disk from dom0: attach the VDI as a VBD to **that host's own control-domain VM** (`xe vm-list is-control-domain=true resident-on=<host>`), `xe vbd-plug`, then `kpartx -av /dev/tda` to get partition device nodes (the root partition was `p1`/`tda1`) — plain `qemu-nbd` doesn't work once the disk is SR-managed (VHD), and dom0's kernel doesn't auto-expose tapdisk partitions without `kpartx`.
  8. Before templating, sealed the image: removed the NoCloud seed directory entirely (critical — leaving it would make every future clone share the same baked-in instance-id and skip re-provisioning), cleared cloud-init state/logs, removed SSH host keys, zeroed `/etc/machine-id`.
- Cleaned up 5 leftover empty templates from an earlier abandoned attempt at this same task (`cloud-ubuntu-24.04`, `cloud-ubuntu-2404`, `ubuntu-cloud-img-2404`, `cloud-img-24`, `cloudimg-ubuntu-2404` — all had no real VBD/VDI, confirmed before deleting).
- **Not yet done for the template**: per-host cluster-join cloud-init (hostname, k3s token, server address) still needs to be supplied at VM-creation time per the provisioning-model plan below — this template is the pre-join base only.

## Possible tamarin-01 sighting (unconfirmed, 2026-08-29)
- While debugging the base template's networking, a bridge capture on tamarin-03 (`xenbr0`) showed a physical MAC (`f4:1e:57:1a:0b:08`, **not** any of the 4 current hosts' or any VM's MAC) sending DHCP requests continuously with no reply for hours (`secs` field over 20000). This could be tamarin-01 back online and trying to rejoin the network after its earlier hang — worth checking against tamarin-01's known NIC MAC if available, and worth checking the DHCP server/router for why it's not answering (reservation-only pool? exhausted range?).

## k3s cluster — bootstrapped 2026-08-29

4 nodes, one VM per physical host, all running as `control-plane,etcd` (per the "all nodes as k3s server nodes" decision). Cluster is healthy — all 4 `Ready`.

| VM name | Physical host | Static IP | VM uuid | VIF MAC |
|---|---|---|---|---|
| k3s-tamarin-03 | tamarin-03 | 192.168.2.102 | `f16e65d0-b8ce-c411-7b77-6929ef976fde` | `02:00:00:00:00:02` |
| k3s-tamarin-02 | tamarin-02 | 192.168.2.101 | `8ca1287d-e549-11e3-7c51-280ef78f42fd` | `02:00:00:00:00:01` |
| k3s-tamarin-04 | tamarin-04 | 192.168.2.103 | `3acf9626-4b76-a830-9f81-5bb3a3fdfdfb` | `02:00:00:00:00:03` |
| k3s-tamarin-05 | tamarin-05 | 192.168.2.104 | `75d5159b-edb7-06ba-9cd8-903366792f6d` | `02:00:00:00:00:04` |

- **Memory: maxed out per-host, 2026-08-30.** Each host's total RAM differs (tamarin-02/03/04 are ~15.9GiB hosts via `xe host-param-list memory-total`; tamarin-05 is ~19.9GiB), and each host runs exactly one non-dom0 VM (the k3s VM) alongside its dom0 control domain — so per-VM headroom = host `memory-total` − dom0 `memory-static-max` − a safety buffer (~0.5-1GiB, for host-level overhead; dom0 on these hosts has dynamic-min=dynamic-max=static-max, i.e. no ballooning slack of its own). Resulting sizes (`memory-static-max=memory-dynamic-max`, `memory-dynamic-min`/`memory-static-min` left unchanged at `6442450944`/`1073741824`):
  | VM | New static/dynamic-max |
  |---|---|
  | k3s-tamarin-02 | 13.5GiB (`14495514624`) |
  | k3s-tamarin-03 | 13.5GiB (`14495514624`) |
  | k3s-tamarin-04 | 13.5GiB (`14495514624`) |
  | k3s-tamarin-05 | 16.5GiB (`17716740096`) — bigger bump since its host has ~4GiB more physical RAM than the other three |

  Previously all 4 were a uniform 12GB fixed (bumped 2026-08-29 from an initial unconsidered 2GB template leftover). Went uniform-then-asymmetric because the hosts themselves aren't uniform — don't assume all 4 k3s VMs are the same size going forward, check `xe vm-param-list` per VM.
  - **Gotcha**: `xe host-list` run over SSH without specifying `uuid=` returns ALL pool hosts' rows, not just the one you SSH'd into (it's pool-wide XAPI) — grabbing "the first host" from that list without filtering by hostname/uuid silently gives you a random pool member's data, not the host you think you're querying. Cost real time here: an early per-VM headroom calc was wrong for tamarin-05 because it picked up tamarin-02's `memory-total` instead of tamarin-05's actual (larger) one.
  - Resized via a rolling `kubectl cordon`/`drain` → `xe vm-shutdown` → `vm-param-set` → `vm-start` → `uncordon` per node, one at a time, keeping etcd quorum (3-of-4) up throughout. XCP-ng only allows changing a VM's static memory range while halted, not live. `xe vm-shutdown`/`vm-start`/`vm-param-set` are pool-wide XAPI calls — ran them all from the pool master (tamarin-03, 192.168.2.16) rather than needing to SSH to each VM's own host.
  - Gotcha: right after `kubectl wait --for=condition=Ready`, the node's reported `status.allocatable.memory` can still reflect the *pre-resize* value for a few more seconds (kubelet hasn't refreshed yet) — don't trust an immediate post-wait capacity read as final; re-check a few seconds later if the number looks stale/wrong.
  - Gotcha hit during this (2026-08-29 resize, applies to any `local-path` PVC): `local-path` pins a pod to whichever node it first ran on — draining that node doesn't relocate it, the pod just goes `Pending` until the same node comes back, then reschedules there automatically. Expected/fine, not a bug.
- **k3s-tamarin-03 is the cluster-init node** (`K3S_CLUSTER_INIT=true`, started first); the other 3 joined via `K3S_URL=https://192.168.2.102:6443`. If it's ever rebuilt, the others would need to be told about whichever node becomes the new join target.
- **Static IPs, not DHCP** — deliberate choice: k3s/etcd peer URLs are pinned to the IP each node had at join time, so a DHCP renewal onto a different address would break etcd peering. Assigned `.101`–`.104` (free at the time, checked by ping first), gateway/DNS pulled from dom0's own resolv.conf (gateway `192.168.2.1`, DNS `192.168.2.1` + `207.164.234.193`).
- **Shared cluster token**: not recorded here. Read it from a running node (`/etc/systemd/system/k3s.service.env`) or `cd terraform/10-vms && terraform output -raw k3s_token`. A rebuild generates a fresh one; you only need the existing value to join a node to the cluster that is already running — e.g. when tamarin-01 comes back. Lives in `K3S_TOKEN` in `/etc/systemd/system/k3s.service.env` on every node.
- **VIF MACs were pinned explicitly** (`02:00:00:00:00:0N`) rather than left auto-generated, so each node's cloud-init `network-config` (matching by MAC) could be prepared before boot.
- **vCPUs: all 4 given all 4 physical cores, 2026-08-31** (`VCPUs-max=VCPUs-at-startup=4`, up from an unconsidered 2-vCPU template default; confirmed via `xe host-param-get param-name=cpu_info param-key=cpu_count` that all 4 hosts, including the bigger-RAM tamarin-05, are 4-core). One VM per host with no other guests resident, so this hands the whole host's CPU to k3s (dom0 still shares the same physical cores — normal Xen behavior, not a problem with a single guest). `VCPUs-max` requires a halt to raise (same as memory-static-max) — did the same rolling `cordon`/`drain` → `xe vm-shutdown` → `vm-param-set` → `vm-start` → `uncordon` one node at a time. Transient `apiserver not ready` from `kubectl` on the node that had *just* restarted, right after its own resize — resolved itself in ~15s, not a real failure, just kubelet/apiserver still warming up.
- **How each VM was created**: `xe vm-clone` for k3s-tamarin-03 (same-host as the template, so it's an instant same-SR clone); `xe vm-copy sr-uuid=<target host's local-storage>` for the other 3 (a real ~21GB network copy per host — the template's OS disk is thick-provisioned so this isn't a fast COW clone, takes a few minutes each over 1GbE). **Gotcha**: both `xe vm-clone` and `xe vm-copy` of a *template* inherit `is-a-template=true` on the copy — always `xe vm-param-set uuid=<new-vm> is-a-template=false` afterward or it won't boot. Also, `xe sr-list`/`vdi-param-get` on a target SR can report stale (pre-copy) `physical-utilisation` until you `xe sr-scan` it.
- **Per-node cloud-init** (hostname, static-IP network-config, k3s role) was injected the same way as the template build: mount the VM's own OS-disk VDI via that VDI's *own host's* dom0 control domain (`xe vbd-create`+`vbd-plug` to `xe vm-list is-control-domain=true resident-on=<host>`, then `kpartx -av /dev/tda`, mount `tda1`), drop files into `/var/lib/cloud/seed/nocloud/{user-data,meta-data,network-config}`, unmount, detach. Must run this on the host that actually owns the VDI post-copy, not always tamarin-03.
- Cleanup: removed the temporary `/root/seed-k3s-tamarin-XX` scratch dirs from each host after seeding.

## Compute headroom note (2026-09-07)
- k3s VM sizing (RAM/vCPU, documented above under "k3s cluster") was maxed out **before** any of Postgres/cert-manager existed. All of this landed on top of that same fixed headroom — nothing's been resized since. Worth revisiting node RAM/CPU if things start getting tight as more workloads land.

## Publishing a site — cert-manager + Traefik

**This layer does not track which websites exist.** A site is its own repo: app code, its
own `k8s/` (Deployment, Service, Ingress), and a `GitRepository`+`Kustomization` under
`clusters/tamarin/` so Flux applies it as the owning tenant. Nothing here needs a list of
domains, and no site TLS certificate is kept at this level — cert-manager issues one from
the Ingress in the site's own repo.

What this layer provides, once, for all of them:

- **cert-manager** installed as a `HelmChart` CR in `kube-system` (repo
  `https://charts.jetstack.io`, chart `cert-manager`, `installCRDs: true`), namespace
  `cert-manager`. In Flux at `clusters/tamarin/platform/operators.yaml`.
- **ClusterIssuer `letsencrypt-prod`** — ACME HTTP-01 solved through Traefik
  (`ingressClassName: traefik`), contact `admin@monke.ca` (deliberately not the user's
  personal address; Let's Encrypt is a third party that gets it for expiry notices). In Flux
  at `clusters/tamarin/platform-config/cert-manager-issuer.yaml`.
- Traefik itself is a **k3s-bundled chart** — only its `HelmChartConfig` is ours. See the
  platform README in the repo.

### Prerequisites that live outside the cluster
Both must be right *before* an Ingress is applied, or the HTTP-01 challenge hangs forever
rather than failing:
- Router forwards **80 and 443 → `192.168.2.200`** (the MetalLB ingress VIP, **not** a node
  address — see "Ingress HA").
- The domain's DNS/DDNS points at the house's public IP. A domain pointing elsewhere leaves
  its challenge pending indefinitely with no useful error.
- DHCP pool stays `.10-.99` so it cannot hand out a VIP or a node address.

### To publish a site
Give the site's repo an `Ingress` with `cert-manager.io/cluster-issuer: letsencrypt-prod`,
`ingressClassName: traefik`, and a `tls` block naming a Secret. cert-manager creates the
`Certificate` and fills the Secret in. Two replicas with required pod anti-affinity plus a
PDB is the house pattern, so losing a node does not take the site down — see
`tenant-kits/*/repo/k8s/` for a working example, and
`templates/project-kustomization.example.yaml` for the Flux side.

### Gotchas worth keeping
- **Renaming an Ingress silently breaks renewal.** cert-manager's `Certificate` is owned by
  the Ingress that requested it, so deleting that Ingress garbage-collects the Certificate —
  but the TLS `Secret` survives, and a new Ingress refuses to adopt it (*"certificate
  resource is not owned by this object"*). The site keeps serving a valid certificate that
  nothing is renewing. After any rename, delete the orphaned Secret too and let cert-manager
  reissue.
- **Let's Encrypt allows 5 duplicate certificates per domain per week.** Use the **staging**
  issuer for anything iterative, especially rebuild drills.
- A domain whose DNS resolves somewhere else (an old host, a parked page) will never
  validate. Check with `dig +short <domain>` against the house's public IP first.
- With no Ingress for a hostname, Traefik answers with its own default self-signed
  certificate, so clients report an SNI/name mismatch rather than a 404. That is the
  "nothing is configured for this domain" signal, not a fault.

## Garage (S3) — operating notes

- **Admin commands go through the pod, and the image is distroless** — no shell, no `ls`, no
  `which`. The `garage` binary is at `/garage` as the entrypoint, so it is
  `kubectl exec -n garage garage-0 -- /garage <subcommand>`, never a shell session. `k9s`'s
  `s` (shell) fails on these pods for the same reason.
- **A fresh Garage does nothing until it has a layout.** Nodes find each other but hold no
  data ranges, so every S3 call fails while the pods look healthy.
  `terraform/scripts/garage-layout.sh` assigns and applies it, putting each node in a zone
  named after its k3s node so replicas land on different hypervisors.
- `layout show` prints **16-char short node ids** while `node id -q` returns the full 64 —
  compare prefixes or an idempotency check never matches.
- **Keys can be recreated with their original IDs**: `garage key import <key-id> <secret-key>
  --yes`. This is what makes restore-from-backup work, since restored objects are owned by
  the original key ID. Verified present in Garage v2.2.0.
- **From dt2**, Garage is reachable on the S3 NodePort `30390` at any node IP. It is not real
  AWS, so every call needs the endpoint and path-style addressing:
  ```bash
  aws --endpoint-url http://192.168.2.101:30390 s3 ls s3://<bucket>/
  ```
  `aws-cli-v2` is installed (pacman `extra`). There is a configured `garage` profile, but its
  key is scoped to a single bucket, so it is not an admin credential — a broader key would
  have to be created deliberately, and hasn't been.

## Postgres — deployed 2026-09-07
Installed the same "HelmChart CR in kube-system, no local helm CLI needed" pattern used for cert-manager.

- **Postgres**: CloudNativePG operator (repo `https://cloudnative-pg.github.io/charts`, chart `cloudnative-pg`, namespace `cnpg-system`). A `Cluster` named `pg` in namespace `postgres`, **3 instances** (1 primary + 2 streaming replicas, preferred pod anti-affinity — landed one per node: pg-1/tamarin-05, pg-2/tamarin-02, pg-3/tamarin-04), `local-path` storage, 10Gi each. Bootstrapped with an `app`-owned database also named `app`.
  - Services (all ClusterIP, ns `postgres`): `pg-rw` (primary, read-write), `pg-ro` (replicas, read-only), `pg-r` (any instance) — always connect to `pg-rw` for writes.
  - Credentials: auto-generated by the operator into Secret `pg-app` (ns `postgres`) — keys `username`/`password`/`dbname` (all currently `app`/`<random>`/`app`). No separate superuser secret exists (`enableSuperuserAccess` wasn't set, so CNPG disabled it by default — the operator manages the cluster without needing a superuser password floating around).

## Terraform rebuild path — written 2026-09-07 (`./terraform/`)

Disaster-recovery IaC for the whole stack: base template → VMs → k3s → operators → workloads. **Not applied against the live cluster** and not imported into state — it's a rebuild path, and running `apply` on the running cluster would collide with everything that already exists (and would install the operators as real Helm releases where they're currently k3s `HelmChart` CRs). See `terraform/README.md` for the full writeup; only the decisions worth knowing at this level are repeated here.

- **Three root modules, applied in order**, split because each configures its providers from the previous one's outputs (layer 20 can't build a Kubernetes provider before layer 10 has produced a cluster):
  | Layer | Builds |
  |---|---|
  | `terraform/10-vms/` | 4 VMs via the `vatesfr/xenorchestra` provider, one pinned per host with `affinity_host`, cloud-inited into k3s servers. Fetches the admin kubeconfig to `terraform/kubeconfig`. |
  | `terraform/20-platform/` | kube-router, MetalLB + ingress VIP, kube-vip + control-plane VIP, Traefik HA config, cert-manager + `letsencrypt-prod` ClusterIssuer, CNPG operator, Garage. |
  | `terraform/30-workloads/` | `pg` Cluster, tenant namespaces (yarn/cubesnail), the three sites + Ingresses. |
- **Out of scope, deliberately**: all data; the XCP-ng pool itself; the `tamarin-k3s-base` template (its build is an image-import process, documented above, not something Terraform expresses); router port-forwards and DNS.
- **The provider replaces the manual cloud-init seeding entirely** — `cloud_config`/`cloud_network_config` on `xenorchestra_vm` do what the qemu-nbd/kpartx VDI-mounting dance did by hand. That whole procedure is now only needed for building the template itself.
- **Chart versions are pinned** to what's running: cert-manager `v1.21.1`, cloudnative-pg `0.29.0`, metallb `0.16.1`, kube-vip image `v1.2.3`.
- **Provider-specific gotcha**: `xenorchestra_vm` has no `wait_for_ip`. Waiting for boot is expressed as `expected_ip_cidr` on the `network` block instead.
- **`prevent_destroy` is set on all four node VMs** — destroying one drops an etcd member, including as the destroy half of a replacement. Comment the `lifecycle` block out deliberately when a node genuinely needs rebuilding, one at a time.
- **Three things can't be Terraform resources** and run as scripts via `local-exec` (all idempotent, all verified against the live cluster): Garage's `layout assign`/`layout apply` (a fresh Garage cluster is inert until it has a layout), Garage bucket + bucket-scoped key creation, and the site-content upload. The bucket script writes its generated credentials straight into a Kubernetes Secret, so per-site Garage keys never enter Terraform state.
  - Those scripts prefer a local `kubectl` and fall back to running `kubectl` on a node over SSH, since dt2 has neither `kubectl` nor `terraform` installed as of writing (`sudo pacman -S terraform kubectl` — both are in `extra`).
  - `layout show` prints **16-char short node ids** while `node id -q` returns the full 64 — compare the prefix or the idempotency check never matches.
- **Generated, not hardcoded**: k3s join token, Garage RPC secret. Fresh values are correct for a rebuild; each has a variable to override when matching a cluster that's still running (which is the case when adding a node). Postgres is untouched — CNPG generates `pg-app` itself.
- **Garage-backed site Deployments set `wait_for_rollout = false`**: on a fresh rebuild the bucket exists but is empty, so the fetch initContainer fails and the rollout never completes. Pods sit in `Init` until `terraform/scripts/upload-site.sh` runs. That's the expected state, not a failure.
- State files, tfvars and the fetched kubeconfig are gitignored — they hold the same class of credentials this file does. `.terraform.lock.hcl` is deliberately **not** ignored.

## Multi-tenant developer bundles — built 2026-09-07 (`cubesnail`, `yarn`)

Both friend namespaces were turned into self-serve tenants that can develop against the
shared infra (pg/garage, plus a Redis of their own) with scoped, non-admin credentials. Kits for handover live
in `/home/yarn/infra/tenant-kits/<tenant>/` (`repo/` is safe to commit; `CREDENTIALS.md`
and `kubeconfig-*.yaml` are mode-600 and must be handed over out of band).

- **Postgres**: role `<tenant>` + two databases (`<tenant>`, `<tenant>_dev`) on the existing
  shared `pg` cluster — deliberately *not* a second CNPG cluster (3 more pods for one tenant
  is waste, and PG role isolation is strong). `public` schema in each is owned by the tenant.
  `CONNECT` was **revoked from `PUBLIC` on every tenant database and on `app`** — without that
  revoke any role can connect to any database, so tenant isolation would be nonexistent. The
  `app` owner is unaffected (database owners hold CONNECT implicitly). Verified both ways.
  - Provisioning script: **`./scripts/pg-tenant.sh`** (also at `/root/pg-tenant.sh` on the k3s nodes). Idempotent; takes tenant name + password. Creates the role, `<tenant>` and `<tenant>_dev` databases, and does the `REVOKE CONNECT ... FROM PUBLIC` that makes the isolation real. Not yet expressed in Terraform — see the tenant gap noted above.
- **Redis**: a **dedicated single-pod StatefulSet per tenant** in the tenant's own namespace
  (`redis:7-alpine`, `--requirepass` from the tenant Secret, appendonly on, 2Gi `local-path`).
  Deliberately not one shared Redis: a single Sentinel set has one password and no
  per-tenant ACLs, so tenants would be able to read and `FLUSHALL` each other's keys. Single-pod (not HA) is a
  deliberate fit with the "a few minutes of downtime is fine" philosophy.
- **Garage**: bucket `<tenant>-data` + bucket-scoped key `<tenant>-data-key`, same pattern as
  `monke-ca-key`.
- **Secrets** (per namespace, consumed by Deployments via `secretKeyRef`, never hardcoded):
  `<tenant>-pg` (incl. ready-made `uri`/`uri_dev`), `<tenant>-redis`, `<tenant>-garage`.
- **NetworkPolicy `isolate-egress` was rewritten** (both namespaces) from the old permissive
  version to genuine default-deny. Allowed: own namespace, kube-system DNS :53, `postgres`
  :5432, `garage` :3900, and the public internet **excluding** `10.42.0.0/16` (pods),
  `10.43.0.0/16` (services), `192.168.2.0/24` (home LAN) and link-local.
  - The old policy's only exclusion was the pod CIDR, which left the **entire service CIDR
    and the whole home LAN reachable** from tenant pods — i.e. the kube API, cluster
    NodePorts, XO and dom0 SSH. That is what the rewrite closes.
  - Verified with throwaway pods in each namespace: pg/own-redis/garage/DNS/internet ALLOW;
    kube API, other tenant's Redis, dom0 :22, LAN NodePorts all BLOCK.
- **RBAC**: the `<tenant>-admin` Role / `<tenant>-user` SA grant namespaced CRUD on
  pods/services/configmaps/secrets/PVCs/deployments/jobs/ingresses, plus `pods/exec`,
  `pods/portforward` and `policy/poddisruptionbudgets`. Kubeconfigs generated from the SA
  token secrets; verified they can manage their own namespace and are Forbidden on nodes
  and on the other tenant's namespace.
  - `pods/portforward` and PDBs were added 2026-09-08 so a tenant can reach Postgres from a
    laptop (see the pg relay below) and so their repo can describe its whole workload —
    a PDB is required by the 2-replica site pattern, and without the rule `kubectl apply`
    of their own manifests fails halfway.
  - **Gotcha, cost real time**: `kubectl auth can-i create pods/portforward` returned **yes**
    while the actual port-forward was **Forbidden**. RBAC treats `pods/portforward` as a
    distinct subresource that a `pods` rule does not cover, but `auth can-i` reports a false
    positive here. Trust a real API call, not `can-i`, when checking subresource access.
- **Deploy model: the friend runs `kubectl apply -k k8s/` themselves** over the tailnet, with
  manifests versioned in their repo. An in-cluster git-pull reconciler was designed and then
  dropped — it only existed to avoid an inbound path, and Tailscale provides one anyway; RBAC
  is the actual boundary either way.
- **Their Claude learns the environment from `repo/CLAUDE.md`** (endpoints, env var names,
  the stateless/no-PVC rule, quota, deploy commands — **no credential values**) plus a
  `repo/.claude/settings.json` allowlisting the sanctioned commands. This is what replaced the
  idea of exposing an MCP server: Claude Code has Bash, so the credential is the security
  boundary, not the tool surface, and an MCP server would have added a public service to secure
  without adding a boundary.
- **Postgres from a laptop: a relay pod, deliberately not a NodePort** (settled 2026-09-08).
  Postgres has no NodePort, and a tenant kubeconfig cannot port-forward into the `postgres`
  namespace. A NodePort for `pg-rw` would have fixed it in one line but exposes Postgres to
  every device on `192.168.2.0/24`, permanently, to buy a convenience — so instead each kit
  ships `k8s/dev/pg-relay.yaml`: a `socat` pod in the tenant's *own* namespace forwarding to
  `pg-rw`, which they port-forward to. Access stays gated by the kubeconfig they already have,
  the relay only exists while they are using it, and no new LAN surface is created.
  - `kubectl apply -k k8s/dev/` then `kubectl port-forward deploy/pg-relay 5432:5432`, and
    connect to `localhost:5432`. Kept in a separate kustomize target so it cannot be applied
    as part of a release. Verified end-to-end as the tenant: real Postgres answered with a
    SCRAM-SHA-256 challenge.
  - This is why the tenant Role needed `pods/portforward` (see the RBAC note above).
- **Pod Security admission added 2026-09-07 (after the fact — the bundle was incomplete without it).**
  The tenant Role grants pod-create, and with no PSA in place a tenant could create a
  `privileged` + `hostPath: /` + `hostNetwork` pod. Verified as an actual escape with the
  tenant kubeconfig: it read `/var/lib/rancher/k3s/server` (agent-token, cred, db) off the node,
  and `hostNetwork` bypassed the NetworkPolicy entirely (reached dom0 :22, which is BLOCK for a
  normal pod). **NetworkPolicies do not apply to hostNetwork pods** — that is the key thing to
  remember; egress rules are not a boundary on their own if a tenant can set `hostNetwork: true`.
  - Fix: `pod-security.kubernetes.io/enforce=baseline` (+`enforce-version=latest`,
    `warn`/`audit=restricted`) on both tenant namespaces. Re-verified: the same pod is now
    Forbidden, and ordinary pods still schedule. `restricted` was deliberately **not** enforced —
    it requires runAsNonRoot/seccomp/dropped-caps and would break stock images like
    `nginx:alpine`; it is set to warn/audit only, so the warnings on tenant pods are advisory.
  - Existing workloads were rollout-restarted to confirm they still admit under `baseline`.
- **Terraform coverage is partial.** `30-workloads/tenants.tf` builds the namespace, SA,
  Role + binding, ResourceQuota, LimitRange and both NetworkPolicies. Still missing from the
  rebuild path: the per-tenant **Redis** StatefulSet, the tenant's **Postgres role and
  databases** (`scripts/pg-tenant.sh` is not wired in), and the **registry**. A rebuild
  therefore yields tenants who have a namespace and permissions but no cache, no database
  role, and dangling image references.

## Internal container registry — deployed 2026-09-07

Self-hosted registry so images can be shipped without an external service. Built when
external registries were off the table.

**GHCR is now acceptable** (user reversed this 2026-09-08, when picking a CI model): if
builds move to hosted GitHub Actions, the runner cannot reach `192.168.2.101:30500`, and
pushing to GHCR is what removes the need to own a build runner at all. That leaves this
registry's role narrowed to LAN-local pushes rather than being the only option — decide
whether to keep it once the CI shape is settled, and note that tenant image references and
`/etc/rancher/k3s/registries.yaml` on every node point here today.

- **`registry:2.8` in namespace `registry`**, exposed as **NodePort `30500`**. Internal/LAN
  only — no Ingress, no public exposure. Friends push over the tailnet.
- **Storage is Garage, not a PVC** (bucket `registry`, key `registry-key`), consistent with
  the stateless/no-PVC policy — Garage does its own replication.
- **Auth**: htpasswd (bcrypt) with one user per tenant, in Secret `registry-auth`. Each tenant
  namespace has an `imagePullSecret` named `registry-creds`.
  - **No per-repository ACLs** — any authenticated user can push/pull any path. `/​<tenant>/` is
    convention only. Harbor would fix this and is far too heavy for 4-core nodes; accepted.
- **Canonical image prefix: `192.168.2.101:30500/<tenant>/<image>:<tag>`.**
- **Admin account added 2026-09-07**: user `admin`, password in `secrets/registry--registry-admin-password.sops.yaml` (htpasswd entry appended
  to Secret `registry-auth`; tenant entries preserved). For pushing your own images.
  Pushing from dt2 needs `/etc/docker/daemon.json` containing
  `{ "insecure-registries": ["192.168.2.101:30500"] }` then `systemctl restart docker` —
  the registry is plain HTTP and Docker refuses it otherwise. **Not done yet (needs sudo).**
- **Node config**: `/etc/rancher/k3s/registries.yaml` on all 4 nodes, then a rolling
  `systemctl restart k3s`. k3s renders it to
  `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<registry>/hosts.toml` — **not** into
  `config.toml`, which is where you would look first and find nothing.
  - The file names `192.168.2.101:30500` as the image host but lists **all four node IPs as
    endpoints**, so pulls survive any single node being down even though the image name is
    pinned to `.101`.
  - k3s restarts leave `containerd-shim` processes alive, so running pods survive; no
    cordon/drain was needed.
- **The gotcha that cost the most time**: with the S3 storage driver the registry **302-redirects
  clients to a presigned Garage URL**. Node containerd is on the host network and cannot resolve
  `garage-s3-api.garage.svc.cluster.local`, so pulls failed with `lookup ... Try again` on every
  node — while appearing to work on the one node that had already cached the layer. Fix is
  **`REGISTRY_STORAGE_REDIRECT_DISABLE=true`**, which makes the registry stream blob content
  itself. Any S3-backed registry serving host-network clients needs this.
- Verified: push via skopeo, blobs land in Garage (8 objects), and a pull succeeds on all four
  nodes. A test image `cubesnail/alpine:3.20` was left in the registry.
- **Scaled to 2 replicas with required anti-affinity + a PDB, 2026-09-07.** Storage is Garage,
  not a PVC, so the registry was already stateless and nothing else had to change — but one
  thing did:
  - **`REGISTRY_HTTP_SECRET` must be set and shared across replicas** (Secret `registry-http`,
    key `secret`). A push is several HTTP requests — POST to start an upload, then PATCH/PUT —
    and the upload state travels in the URL signed with this secret. Each replica generates a
    random one if it is unset, so behind a round-robin Service a push whose requests land on
    different pods fails with an "invalid state" error. It was unset here; scaling without
    fixing it would have broken pushes intermittently and confusingly.
  - Verified after scaling: three multi-layer `nginx:alpine` pushes through the ClusterIP
    Service (which load-balances across both pods) all succeeded with matching digests and
    pulled back cleanly.
- **Not in Terraform.** `terraform/` has no registry resources at all — a rebuild produces a
  cluster with no registry, and every tenant image reference would dangle.

## Tenant repo kits — `/home/yarn/infra/tenant-kits/<tenant>/`

What a friend receives. `repo/` is safe to commit into their app repo; `CREDENTIALS.md` and
`kubeconfig-*.yaml` are mode-600 and go out of band.

- **`repo/CLAUDE.md`** — ambient facts only: service endpoints, env var names, stateless rule,
  PSA baseline, egress limits, quota. Always loaded, no credential values.
- **`repo/.claude/skills/deploy/`** and **`.../troubleshoot/`** — procedures, loaded on demand so
  they cost nothing while writing ordinary app code. `deploy` covers both the image path and the
  static Garage-tarball path; `troubleshoot` is keyed to this cluster's actual failure modes —
  **blocked egress presents as a hang, not an error**, PSA rejections look like manifest syntax
  errors, `local-path` pins pods to a node, `logs --previous` for crashloops.
- **`repo/.claude/settings.json`** — allowlists the sanctioned commands so their Claude is not
  prompted constantly, with `.env` and kubeconfigs denied.
- **`repo/k8s/`** — the manifests for what the tenant actually runs, so the repo is the
  source of truth rather than the cluster: `site.yaml` (Deployment + Service + PDB, 2
  replicas with required anti-affinity), `ingress.yaml` (their domain, cert-manager
  annotated), `dev/pg-relay.yaml` (the laptop Postgres path, separate kustomize target),
  and `deployment.yaml` — a container-image scaffold left commented out of the
  kustomization until they have an image to ship. All carry `imagePullSecrets:
  registry-creds`; without it a pod pulling from the internal registry gets a 401 from the
  node and sits in `ImagePullBackOff`.
- **There is no kit template or generator yet** — `tenant-kits/` holds only the two
  per-tenant copies, and every change so far has been hand-applied to both. A
  `tenant-kits/template/` plus a `new-tenant.sh` (mirroring `app-starter/new-app.sh`) is
  the fix; deferred deliberately until the deploy model settles, since CI is likely to
  change what a kit even contains.

## GitOps — Flux, bootstrapped 2026-09-08

Deploys are pull-based: Flux runs in the cluster, polls GitHub, and applies what it finds.
Nothing reaches into the cluster from outside, which is what makes this work without the
tailnet/inbound path that was blocking CI.

- **Repo: `monkecloud/infra`** (private, GitHub org `monkecloud`, free plan). Flux watches
  `clusters/tamarin/`. Auth is a **read-only deploy key** generated by bootstrap, not a
  personal token — nothing in the cluster can write to GitHub.
- **Only two controllers installed**: `source-controller` (clones git) and
  `kustomize-controller` (applies it). `--components=source-controller,kustomize-controller`
  on bootstrap. helm-controller and notification-controller are unused here.
  **Actual footprint: ~30Mi and 3m CPU total** — far below the ~256Mi the defaults request.
- Bootstrap command, if it ever needs redoing:
  ```
  export GITHUB_TOKEN=$(gh auth token)
  flux bootstrap github --owner=monkecloud --repository=infra \
    --path=clusters/tamarin --private=true \
    --components=source-controller,kustomize-controller
  ```

### Gotchas hit during setup
- **A new GitHub org has `deploy_keys_enabled_for_repositories: false`**, and bootstrap fails
  at the deploy-key step with a bare `422 Deploy keys are disabled for this repository` —
  which reads like a repo problem but is an org policy. Fix is one API call:
  `gh api -X PATCH /orgs/<org> -f deploy_keys_enabled_for_repositories=true`, then re-run
  bootstrap (it is idempotent and picks up where it left off).
- **Bootstrap's default intervals are asymmetric**: GitRepository polls every 1m but the
  Kustomization reconciles every **10m**, so a push can take up to ten minutes to land. A
  fast first test is luck, not the norm. Lowered to 1m here. A webhook would make it instant
  but needs an inbound path, which is exactly what this design avoids.
- Verified end to end: a commit applied without any `kubectl`, and deleting the file removed
  the resource from the cluster (`prune: true` works).

### Planned shape, not yet built
One repo per project, each with a `k8s/` directory Flux applies. Per-tenant `GitRepository`
+ `Kustomization` files are drafted in `/home/yarn/infra/gitops/clusters/tamarin/tenants/`
but **not committed** — they point at project repos that do not exist yet.
- Each Kustomization sets `serviceAccountName: <tenant>-user`, so Flux applies a tenant's
  manifests **as that tenant**. Their existing Role is the deploy boundary; a tenant repo is
  untrusted input, not a privileged one. This is the main reason the design fits here.
- **Namespaces stay per-person, not per-project** (user's call 2026-09-08) — several of the
  user's projects share the `yarn` namespace. Resource names must therefore differ between
  projects in the same namespace; pruning is safe, since a Kustomization only prunes what it
  itself created.
- Images go to **GHCR** (`ghcr.io/monkecloud/<repo>`), built by GitHub Actions using the
  per-run `GITHUB_TOKEN` — no PAT needed and no runner to own. Workflow template drafted at
  `/home/yarn/infra/gitops/templates/build-and-deploy.yml`: it builds, pushes, then commits
  the new tag into the repo's `k8s/`, which is what Flux picks up.


## Rebuild-from-git architecture — decided 2026-09-08, partially built

Goal, in the user's words: spin up the cluster from a GitHub set of definitions, restore data
from backups, "and then it's like nothing ever happened." No state that exists only on the
cluster.

### Division of labour
| Layer | Owns |
|---|---|
| **Terraform** | XCP-ng VMs, k3s, Flux bootstrap — **plus** Garage layout/buckets/keys and Postgres tenant provisioning via the existing `local-exec` scripts |
| **Flux** | Everything else inside Kubernetes |
| **age key** | One line of text in a password manager. The only secret outside git |
| **Backups** | Data only — Postgres, Garage objects. Not yet built |

`20-platform` and `30-workloads` are to be **converted to Flux manifests and removed from
Terraform** — they create Kubernetes objects, which is Flux's job now, and two systems owning
the same resources will drift. `10-vms` stays.

Terraform deliberately still reaches through to the Kubernetes API for the three script-driven
things. Keeping them there costs self-healing (nothing notices if a Garage bucket vanishes
until someone runs Terraform) — **user explicitly accepted that tradeoff** rather than
rewriting working, idempotent scripts as CronJobs.

### The rule that makes restore work
**Every credential an external system or restored data has already seen must be a committed
(SOPS-encrypted) value, never a generated one.** Restored Postgres data carries its role
passwords inside it; Garage objects are owned by specific key IDs. A rebuild that generates
fresh secrets produces a cluster that stands up perfectly and cannot read its own data.

This reverses the earlier "generated, not hardcoded" choice for the k3s token and Garage RPC
secret, and the bucket script's "credentials never enter Terraform state" design. Those are
good state hygiene and they break restore.

- **Must be committed**: tenant `*-pg`/`*-redis`/`*-garage`, `pg-app`, `registry-auth`,
  `registry-http`, `registry-s3`, `letsencrypt-prod-account-key`.
- **Can be generated**: k3s join token, Garage RPC secret, all operator PKI
  (`cnpg-ca`, `*-webhook-cert`, `pg-server`, `pg-replication`, `metallb-memberlist`,
  `k3s-serving`, node-password secrets) — nothing outside a fresh cluster has seen these.
- **Re-issuable**: the `*-tls` certs.
- **`garage key import <key-id> <secret-key>` exists** (verified, Garage v2.2.0) — so Garage
  keys can be recreated with their original IDs and restored objects stay readable. Without
  that command this whole approach would need a Garage-side migration step.

### Secrets: SOPS + age — BUILT 2026-09-08
- **Public key** `age1m530e4zxqtaul455myzut6cqqj39ecvtgzdw3uf59j7xdu9he4fs83w9mq`, committed in
  `monkecloud/infra/.sops.yaml` (`encrypted_regex: ^(data|stringData)$`, so only values are
  ciphertext and manifests stay diffable).
- **Private key** at `~/.config/sops/age/keys.txt` on dt2 (mode 600), in the cluster as Secret
  `sops-age` in `flux-system`, and the user was told to store it in a password manager. **This
  is the single thing not recoverable from git.**
- Flux decrypts natively: `spec.decryption.provider: sops` + `secretRef: sops-age` on the
  `flux-system` Kustomization, committed in `gotk-sync.yaml` so it survives a rebuild.
- **Verified end to end**: an encrypted canary committed to the reconciled path was decrypted
  by Flux into a real Secret, then pruned when removed. Also confirmed by fetching a committed
  file back from GitHub that the plaintext password does not appear in it.
- **17 secrets committed** to `monkecloud/infra/secrets/` — see that directory's README for
  which and why. Deliberately **outside `clusters/tamarin/`, so Flux does not reconcile them**:
  a secret belongs beside the manifest that consumes it, those manifests are still in
  Terraform, and two of the 17 are owned by operators that would fight over them (`pg-app` by
  CNPG, `letsencrypt-prod-account-key` by cert-manager). It is a recovery vault until the
  workloads move into Flux, at which point each secret moves into the reconciled tree.
- Note `yarn/yarn-site-s3-creds` (created 2026-08-31) was **excluded** — an orphan from the
  deleted yarn-site test deployment. Worth deleting from the cluster.

### What is genuinely outside this
1. The `age` key itself.
2. Data (needs the backup target that still does not exist).
3. Getting a base image into XCP-ng — but **no custom image is needed any more**
   (2026-09-08). Cloud-init now installs the pinned k3s version (`k3s_version`, default
   `v1.36.4+k3s1`) plus open-iscsi and nfs-common on first boot, so the official Ubuntu 24.04
   cloud image is sufficient. User's call: "I dont really wanna maintain our own image here."
   `tamarin-k3s-base` still exists and boots faster; **do not rebuild it if lost**. Its build
   writeup above is reference only. Verified by rendering the template with `terraform
   console`; `terraform validate` and `fmt` both clean.
4. Router port-forwards and DNS/DDNS.
5. The GitHub repos themselves — GitHub is now a dependency; a local mirror is worth having.

### Rebuild sequence
1. Install XCP-ng, build the base VM template *(manual)*
2. `terraform apply` in `10-vms` → VMs + k3s
3. Paste the age key into the cluster
4. `flux bootstrap` against `monkecloud/infra`
5. Flux builds the platform, tenants and sites; certs issue themselves
6. Restore data; `garage key import` for the object-store keys
7. Point DNS/router at the new address

Steps 1, 2 and 4 work today. Step 5 is **half done** — see platform conversion below.

### Platform converted to Flux — 2026-09-08
`clusters/tamarin/platform/` and `platform-config/`, driven by two Kustomizations in
`clusters/tamarin/platform.yaml` with `dependsOn` so the operators land before the resources
that need their CRDs (ClusterIssuer needs cert-manager's, IPAddressPool needs MetalLB's).

Now Flux-owned: the cert-manager / CNPG / MetalLB `HelmChart` CRs, Garage (ns, config, both
Services, StatefulSet), kube-vip, kube-router, the MetalLB pool + L2Advertisement, the
`letsencrypt-prod` ClusterIssuer, and the Traefik `HelmChartConfig`.

- **Method that made this safe**: exported from the live cluster, then `kubectl diff`-ed every
  file against it *before committing*. All seven files came back byte-identical, so adoption
  restarted nothing — verified afterwards too (no pod restarts, both VIPs still held).
  Do it this way for `30-workloads`; translating the Terraform instead would risk applying a
  subtly different spec and bouncing live workloads.
- **Traefik itself is deliberately NOT in git.** k3s ships `traefik` and `traefik-crd` as
  bundled HelmCharts from `%{KUBERNETES_API}%/static/charts/` and recreates them; committing
  them would mean two systems fighting. Only the `HelmChartConfig` is ours.
- **k3s `HelmChart` CRs, not Flux `HelmRelease`** — matches what was already deployed, and is
  why `helm-controller` stays uninstalled. k3s already has a Helm engine; adding Flux's would
  be a second one for no gain.
### Workloads converted to Flux — 2026-09-08
`clusters/tamarin/workloads/` under a `workloads` Kustomization that `dependsOn: platform`
(the `pg` Cluster needs CNPG's CRDs first). Same export-then-diff method; every file came back
byte-identical, nothing restarted.

Now Flux-owned: ns `postgres` + the 3-instance `pg` Cluster; both tenants complete (namespace
with its PSA labels, `<tenant>-user` SA, `<tenant>-admin` Role + binding, ResourceQuota,
LimitRange, both NetworkPolicies, Redis StatefulSet + Service); the internal registry
(ns, Deployment, Service, PDB); and the `placeholder` namespace.

**The registry is in the rebuild path for the first time** — it was previously in no IaC at
all, so a rebuild would have produced a cluster with no registry and every tenant image
reference dangling.

**Eleven secrets moved out of `secrets/` into the reconciled tree** beside the workloads that
consume them: the eight tenant `*-pg`/`*-redis`/`*-garage`/`registry-creds`, and the three
`registry-*`. Verified afterwards that a Flux-applied credential still authenticates
(`psql` as `yarn` on `yarn_dev`) — re-applying a Secret with a changed value would silently
break auth, so this is worth checking rather than assuming.

**Still in `secrets/` as an unreconciled vault**, deliberately:
- `postgres--pg-app` (CNPG owns it), `cert-manager--letsencrypt-prod-account-key`
  (cert-manager owns it) — Flux applying these would fight the operator.
- The three `*-tls` certs and `placeholder--monke-ca-garage-key` — no consumer while the
  sites are torn down. They move into the tree when the sites come back.

### Everything moved into the repo — 2026-09-08
`/home/yarn/infra` was **never a git repo**, so `terraform/`, the five scripts and this file
lived on dt2 only — exactly the single-machine state this whole exercise exists to remove.
A `REBUILD.md` was even written referencing a directory that existed on one machine.

- `terraform/` and `scripts/pg-tenant.sh` are now in **`monkecloud/infra`**.
- **Work from the clone at `/home/yarn/infra/monkecloud-infra/`.** The old
  `/home/yarn/infra/terraform` and `/home/yarn/infra/scripts` were deleted so there is one
  source of truth and no drift.
- **Two real credentials were found and removed while moving**: `root_password` had
  `default = "<pool-root-password>"` in `variables.tf`, and `ssh-lib.sh` had
  `: "${NODE_ROOT_PASSWORD:=<pool-root-password>}"`. Both now have **no default** — Terraform requires
  `root_password` in the gitignored tfvars, and the script exits if `NODE_ROOT_PASSWORD` is
  unset. `terraform.tfvars.example` also carried the live XO login; placeholdered.
- Verified in a clean clone: `terraform init -backend=false && terraform validate` passes,
  `fmt` clean.
- **`CLAUDE.md` (this file) is now in the repo too**, scrubbed of credentials. Only four
  distinct ones were ever in it. `/home/yarn/infra/CLAUDE.md` is a **symlink** into the clone,
  so it still auto-loads for sessions rooted there while there is one copy.
  - Three were regenerated-at-install anyway: the XO login, the pool-wide host root password,
    and the k3s join token.
  - The fourth needed real handling. **`registry-auth` stores htpasswd bcrypt hashes, which
    are one-way** — a rebuild restores the Secret and the registry accepts the old admin
    password, but nothing can derive it. Tenant passwords are unaffected because each
    tenant's `registry-creds` holds `base64(user:password)`, which is reversible; nothing
    pulls as admin, so admin has no `registry-creds`. The plaintext is now vaulted at
    `secrets/registry--registry-admin-password.sops.yaml`.
  - **Do not paste a real credential back into this file.** The two homes are
    regenerated-at-install, or SOPS-encrypted in this repo.

### Terraform trimmed — 2026-09-08
`terraform/20-platform/`, `terraform/30-workloads/` and `terraform/modules/` were **deleted**;
Flux owns those objects now, and two systems describing the same resources is the drift this
exercise exists to prevent. Neither had ever been applied (no `.tfstate` anywhere).

- The two scripts that had to survive lived *inside* the deleted layers —
  `20-platform/scripts/garage-layout.sh` and `30-workloads/scripts/garage-bucket.sh`. Both were
  moved to `terraform/scripts/` and their `kube-lib.sh` source paths fixed.
- **`scripts/point-kubeconfig-at-vip.sh` lost its automatic caller** — it ran from layer 20.
  It is now a manual step after Flux brings kube-vip up, documented in `terraform/README.md`.
  Easy to forget on a rebuild; the kubeconfig otherwise stays pointed at the init node.
- `scripts/upload-site.sh` is kept but now unreferenced.
- Archive of the deleted layers: `/home/yarn/infra/_terraform-superseded-2026-09-08.tar.gz`
  (25KB). `/home/yarn/infra` is **not** a git repo, so this was the only safety net — delete it
  once the rebuild path has been exercised.
- `terraform/README.md` rewritten to cover only the VM/bootstrap layer.
- The local `gitops/` scaffolding was deleted; its useful parts are now in
  `monkecloud/infra/templates/` (the GitHub Actions workflow, and an example project
  Kustomization showing the `serviceAccountName` impersonation pattern).
- Orphan Secret `yarn/yarn-site-s3-creds` deleted from the cluster.

### Caveat when testing a rebuild
A full rebuild re-issues every certificate at once, and Let's Encrypt allows 5 duplicate certs
per domain per week. **Use the staging issuer for rebuild drills**, or a couple of iterations
will exhaust the allowance for the real domains. An untested rebuild path is a hypothesis, not
a recovery plan.


## Backups — design only, NOT built (assessed 2026-09-07)

Nothing is backed up today. **User has no backup target machine yet** — `dt2` is their desktop and is explicitly not a backup destination (asked and answered 2026-09-07). So this is the plan for when a target exists, not something to go implement.

### Current coverage, honestly

| What | State |
|---|---|
| k3s etcd | **Partial.** k3s auto-snapshots every 12h, retention 5 (a k3s default, nobody configured it) — but every copy sits on the node VMs themselves at `/var/lib/rancher/k3s/server/db/snapshots/`. Covers a bad upgrade or corruption; worthless if the VMs are gone. |
| k8s object state | **Mostly** — `terraform/30-workloads` reproduces it. Gaps below. |
| Postgres | **Nothing.** 61 MB total as of 2026-09-07. |
| Redis | **Nothing.** Per-tenant instances only, currently near-empty. User wants it backed up once it holds real data. |
| Garage objects | **Nothing.** One 250KB site tarball today. |
| Whole VMs | **Nothing.** XO backup jobs need a remote and there is none. |

### The constraint that shapes everything
Every candidate target is inside the failure domain being protected. **Garage cannot back itself up** — it runs on the cluster it would be protecting. So the one prerequisite is a single S3-compatible endpoint in a *different* failure domain; every component below then points at it. Three ways to get one:
- **Cloud bucket direct** (Backblaze B2 / Wasabi / S3). Needs no hardware at all, and at current data sizes costs cents a month. This is the lowest-friction start and is worth considering before buying anything.
- **A small dedicated box** (NAS, old PC, Pi + USB disk) running MinIO or single-node Garage. Fast local restores; same building, so it doesn't cover site loss.
- **tamarin-01**, if it ever comes back and is deliberately *not* rejoined to the pool. Free, already on-site, currently dead weight — but same room, same power, same switch.

The usual answer is local for fast restore plus cloud for site loss; either alone is a real improvement over the current nothing.

### Per component, in priority order

1. **Postgres — the one with a proper answer.** CNPG's `spec.backup.barmanObjectStore` (confirmed present in the 1.30 CRD on this cluster) does scheduled base backups **plus continuous WAL archiving**, which means point-in-time recovery to any second, not just "last night". Add a `ScheduledBackup` CR for the base-backup cadence and a `retentionPolicy` (e.g. `30d`). Restore is a new `Cluster` with `spec.bootstrap.recovery` pointing at the object store — so *Terraform rebuild + recovery bootstrap = full restore*, which is exactly the gap the Terraform leaves open.
   - Caveat for upgrades: the CRD also exposes a top-level `plugins` field, and CNPG is moving toward the Barman Cloud Plugin over the in-tree `barmanObjectStore`. In-tree works fine on 1.30; check this at upgrade time rather than assuming it stays.
2. **cert-manager secrets — cheap and high-value.** The ACME account key and issued certs are *not* in Terraform, and Let's Encrypt rate-limits reissues (5 duplicate certs per week per domain set). Losing them means the sites can come back but their certificates might not, for days. A periodic dump of the `cert-manager` namespace secrets plus the per-site TLS secrets is small and prevents a genuinely annoying outage.
3. **Garage.** No native backup. Object-level `rclone sync` (or `aws s3 sync`) to the off-cluster target, as a CronJob. Low stakes right now because the only content is a site tarball *derived* from a git repo — this gets important the moment Garage holds something not reproducible from elsewhere.
4. **etcd.** k3s can upload its own snapshots: `--etcd-s3`, `--etcd-s3-endpoint`, `--etcd-s3-bucket`, `--etcd-s3-access-key`, `--etcd-s3-secret-key`. No cron or scripts needed and it registers `ETCDSnapshotFile` resources. Restore is `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>` on one node, then rejoin the rest. Worth being clear that **with the Terraform, etcd restore is not the primary recovery path** — rebuilding is cleaner. Its value is covering things created outside Terraform.
5. **Redis** (user confirmed they'd want this once it holds persistent data). Each tenant runs a single-pod instance, so a CronJob per namespace running `redis-cli --rdb` against `redis-0` and shipping the RDB to the object store. There is no replica to offload the dump onto, so schedule it when the tenant is quiet. Password comes from Secret `<tenant>-redis`.
6. **VM-level via XO.** Now viable again since the XO fix above. Add a remote (XO supports NFS/SMB/local/S3) and a delta backup job over the 4 k3s VMs plus the `tamarin-k3s-base` template. Coarse net and fast whole-node rollback. Note that a snapshot of a running Postgres is only crash-consistent — CNPG recovers via WAL replay, but the barman backup is the authoritative path, not this.
7. **XO's own state.** `/home/yarn/xo-data/` on dt2 (see XO section). Small, and currently protected by nothing.

### Ordering rationale
Postgres first because it's the only thing holding data that can't be regenerated from a git repo or a Terraform apply. cert-manager second because it's tiny and its loss causes a slow, rate-limited outage. Everything below that is either currently near-empty (Garage, Redis) or largely superseded by the Terraform (etcd, VM-level).

## dt2 tooling

`kubectl` is installed on dt2 and `~/.kube/config` holds the **admin** kubeconfig, originally
copied from `/etc/rancher/k3s/k3s.yaml` on tamarin-02. Its server is
**`https://192.168.2.201:6443`** — the kube-vip control-plane VIP, so `kubectl` survives any
single node dying. Every node IP is also a SAN on the API cert, so
`kubectl --server=https://192.168.2.102:6443` is a valid fallback if the VIP itself ever
misbehaves. Cluster commands do not need to be wrapped in SSH; only dom0/XAPI work does.

**`./tamarin-status.sh`** (in this directory) prints a one-screen overview: nodes and their
load, who currently holds each VIP, every Deployment/StatefulSet with ready counts, the health
of Postgres/Garage/per-tenant Redis, anything not Running, and the Ingresses. Pass `--sites`
to also curl each public domain. Read-only.

**k9s** is the interactive equivalent (`sudo pacman -S k9s stern` — not installed yet):
browse/logs/exec/describe from the terminal, with no web service to expose and no password to
keep. `s` shells into a pod, `l` logs, **`p` previous-container logs (the one for
crashloops)**. Note `s` fails on Garage — that image is distroless with no shell; use
`kubectl exec -n garage garage-0 -- /garage <cmd>` instead.

Note `/bin/fish` is the shell here: unquoted bash heredocs (`<<EOF`) fail to parse. Use a
quoted delimiter (`<<'EOF'`) or write the script to a file first.

## App scaffolding — `/home/yarn/infra/app-starter/` (2026-09-07)

`./new-app.sh <app> <namespace> [domain] [target-dir]` scaffolds an app repo that carries its
own cluster context, so a fresh Claude session in that repo needs no briefing. This exists
because **`/home/yarn/infra/CLAUDE.md` is only auto-loaded for sessions under that directory** —
an app repo at `~/prg/whatever` starts knowing none of this.

- `template/CLAUDE.md` — endpoints, the storage-tier policy, ingress/cert prerequisites.
  Always loaded.
- `template/.claude/skills/{deploy,troubleshoot}/` — procedures, loaded on demand. Carries the
  hard-won gotchas: `REGISTRY_STORAGE_REDIRECT_DISABLE`, Ingress-rename certificate orphaning,
  `logs --previous`, `local-path` node pinning.
- Admin flavour (full kubectl, can create namespaces/roles/buckets). The restricted equivalent
  for friends is `tenant-kits/`.
- Edit `template/` and re-scaffold; don't edit generated repos or they drift.

## Ingress HA — MetalLB VIP + replicated Traefik, built 2026-09-07

Goal driving this: **any one of the hosts going down must not take anything down.** Public
ingress was the obvious hole — the router forwarded 80/443 at a single node IP, so that node
rebooting killed every public site.

- **MetalLB 0.16.1** in `metallb-system`, installed as a `HelmChart` CR in `kube-system` (same
  pattern as everything else here). The chart's **FRR backend is disabled**
  (`frrk8s.enabled: false`, `speaker.frr.enabled: false`) — it defaults to on and costs
  4 nodes × 5 containers for BGP that isn't used in L2 mode.
- **`IPAddressPool ingress-vip`** holds `192.168.2.200/32` with **`autoAssign: false`**, so it
  only ever goes to a Service that names the pool. That was what kept MetalLB and k3s ServiceLB
  from fighting over the Traefik service during the cutover.
- **k3s ServiceLB is disabled**: `/etc/rancher/k3s/config.yaml` on all 4 nodes contains
  `disable: [servicelb]`, applied with a rolling `systemctl restart k3s`. Before this the nodes
  had no `config.yaml` at all and no extra flags in the systemd unit, so the file is the only
  place k3s server options live now.
- **Traefik** claims the VIP via a **`HelmChartConfig`** (ns `kube-system`), not a direct
  `kubectl patch` — a patch gets reverted the next time the packaged chart reconciles.
  Same config also sets `deployment.replicas: 2` with required pod anti-affinity, and
  **`externalTrafficPolicy: Local`**, so only nodes actually running a Traefik pod announce the
  VIP and traffic never takes an extra hop toward a dead node.
- **Retry middleware** (`kube-system-retry@kubernetescrd`, 3 attempts) is wired into both
  entrypoints via `additionalArguments`, together with
  `--serversTransport.forwardingTimeouts.dialTimeout=500ms`.

### Why the retry + dial timeout are load-bearing (measured, not theoretical)
A pod on a hard-powered-off node stays in the Service's EndpointSlice for **~40-70s**, until the
node is marked NotReady. Traefik keeps dialing it the whole time, so **adding a second replica
on its own turned a clean 100% outage into ~50% of requests failing** — better, but still very
visible. The retry moves the request to the live replica; the 500ms dial timeout is what keeps
that retry inside a normal request budget (at the default 30s, and even at 2s, the retry is
slower than any real client will wait).

### Measured failover, hard `xe vm-shutdown force=true` on a node
| Config | Result |
|---|---|
| Single replica per site, k3s ServiceLB | site on the dead node: **5m47s** down (300s default `tolerationSeconds` before eviction, then reschedule) |
| 2 replicas, no retry, dialTimeout 2s | ~50% of requests failing for ~70s (dead endpoint still being dialed) |
| 2 replicas + retry + dialTimeout 500ms | **1 failed probe out of 312** across the whole node loss; VIP moved in ~8s |

- **All three sites are now 2 replicas** with required `podAntiAffinity` on
  `kubernetes.io/hostname` plus a `PodDisruptionBudget` (`minAvailable: 1`):
  `yarn-site` (ns `yarn`), `munke-biz-site` (ns `placeholder`), `cubesnail-site` (ns `cubesnail`).
- **The VIP does not answer ping.** MetalLB's speaker replies to ARP but never binds the address
  to an interface — `ping 192.168.2.200` failing is normal, don't use it as a health check.
- **DHCP pool was shrunk to `.10-.99`** (was `.10-.199`) so the VIP and the node IPs
  (`.101`-`.104`) sit outside it. The nodes were previously inside the pool with no reservations.
- CNPG **does** fail the primary over on node loss, but slower than a 4-minute observation
  window — `status.currentPrimary` stayed stale on a NotReady node for a while before moving.
  Don't read an unchanged `currentPrimary` as "failover is broken".

### Control-plane VIP — kube-vip, `192.168.2.201` (done 2026-09-07)
Closed the last SPOF: `~/.kube/config` used to point at `192.168.2.101`, so killing that one
node left the cluster perfectly healthy but `kubectl` dead.

- **kube-vip v1.2.3** as a `DaemonSet` (`kube-vip-ds`, ns `kube-system`) on all control-plane
  nodes, `hostNetwork: true`, ARP mode with leader election. In Terraform at
  `terraform/20-platform/kube-vip.tf` + `manifests/kube-vip.yaml.tftpl`.
- `svc_enable: "false"` deliberately — **MetalLB owns LoadBalancer Services**, kube-vip only
  owns the control-plane VIP. Leaving both enabled would have them fight over Services.
- `vip_interface: eth0`. Note the k3s VMs' NIC really is **`eth0`**, not the `enX0` that the
  template-build notes above mention.
- Leadership is a `Lease` named **`plndr-cp-lock`** in `kube-system` — that is how you find
  which node currently answers the VIP:
  `kubectl get lease -n kube-system plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'`
- **`tls-san: [192.168.2.201]` had to be added to `/etc/rancher/k3s/config.yaml` on every node**
  (plus a rolling `systemctl restart k3s`) before this worked — the API serving cert only had
  SANs for the four node IPs, so TLS to the VIP would otherwise fail verification. That file now
  holds both `disable: [servicelb]` and the `tls-san` entry.
- `~/.kube/config` on dt2 now points at `https://192.168.2.201:6443`
  (backup of the old one was taken at cutover time).

### Measured: hard power-off of the node holding *both* the CP VIP lease and a Traefik replica
| Metric | Result |
|---|---|
| API (`/readyz` via `.201`) | 1 failed probe out of 110 — roughly a 7s gap |
| Public sites | **220/220 probes OK — zero failures** |
| Recovery on node return | Ready ~30s after boot, all pods settled by ~45s |

So a single host loss now costs ~7-8s of API availability and nothing visible on the public
sites. Remaining single points of failure are the switch, the router, and power.

### All of this is in Terraform (updated 2026-09-07)
The rebuild path now reproduces the HA setup rather than the pre-VIP single-node one:
- `terraform/10-vms/cloud-init/user-data.yaml.tftpl` writes `/etc/rancher/k3s/config.yaml`
  with `disable: [servicelb]` and `tls-san: [<api_vip>]` **before k3s first starts** — the
  SAN cannot be added later without regenerating the apiserver cert and rolling every node.
  Layer 10 and layer 20 both have an `api_vip` variable and they must agree.
- `terraform/20-platform/{metallb,traefik,kube-vip}.tf` build the rest. MetalLB is a real
  `helm_release` here rather than the `HelmChart` CR that is running today — the same
  deliberate difference the README already documents for every other operator.
- Layer 10 still fetches a kubeconfig pointing at the init node (nothing answers on the VIP
  that early); layer 20 repoints it via `terraform/scripts/point-kubeconfig-at-vip.sh`,
  which verifies the VIP with certificate verification **on** and restores the original if
  it fails — that check is what catches a missing `tls-san`.
- `terraform/modules/site` now defaults to **2 replicas** with required anti-affinity and a
  PDB (skipped at 1 replica, where `minAvailable: 1` would block every drain).
- Verified by rendering the templates and diffing against the live cluster: the kube-vip
  manifest is byte-identical, and chart version, pool, Traefik args, middleware and site
  replicas all match.

## Not yet decided / not yet done
- **Backup target machine** — nothing to back up *to* yet; see the backup section above. This is the blocking prerequisite for all of it.
- **Longhorn** — still not installed. Only workload type actually planned for it (something without its own replication) hasn't come up yet.
- **A durable queue / event store as a future global service** — raised 2026-09-08 as the kind
  of thing that would join Postgres and Garage in the durable tier if tenants need it. Kafka
  is the obvious name but is heavy for 4-core nodes (JVM, 3 brokers, ZooKeeper-or-KRaft);
  **Redpanda** (single binary, no JVM) or **NATS JetStream** (much lighter still) are the
  realistic candidates at this size. Nothing needs one yet — don't build it on spec, which is
  exactly how the shared Redis ended up unused.
- tamarin-01's hardware issue is still unresolved (user checking physical console separately) — see possible sighting above. If/when it rejoins the Xen pool (a fresh `xe pool-join` — its old identity is gone), it needs its own k3s VM. Easiest path now is the Terraform one: add an entry to the `nodes` map in `terraform/10-vms/terraform.tfvars` with IP `.105` and set `k3s_token` to the running cluster's token so it joins rather than forming its own. The manual equivalent is `xe vm-copy` to its local-storage SR plus a cloud-init seed with the shared token above.
- Cloudflare Tunnel for friend-hosted content — considered and not built. Friend sites are
  exposed the same direct way as the user's own (port-forward → Traefik → cert-manager), per
  the user's 2026-09-07 call. Revisit if a friend ever deploys something unaudited.
- **Tailscale — no longer needed for deploys.** It was the blocking prerequisite for CI while
  the plan was push-based (a hosted runner cannot reach `192.168.2.x`). Flux pulling from
  GitHub removed that need entirely, and a tenant's laptop reaches Postgres through the
  in-namespace relay rather than the tailnet. Still genuinely open for **admin access** —
  `kubectl` and SSH are LAN-only, so nothing works from outside the house. Not urgent.
- **No sites are deployed, and none are tracked here** (user's call 2026-09-08 — the infra
  layer should not carry a list of websites). A site is its own repo; to publish one, see
  "Publishing a site" above and `templates/project-kustomization.example.yaml`.
- **No project repos exist yet.** `monkecloud/infra` is the only repo in the org.
- **The rebuild path has never been run.** Every piece was verified individually — manifests
  diffed byte-identical against live, Flux adoption caused zero restarts, a Flux-applied
  credential authenticated — but that is not the same as a rebuild working end to end. The
  four ⚠ manual steps in `REBUILD.md` are where it would most likely go wrong, precisely
  because nothing automated catches a mistake there. Use the Let's Encrypt **staging** issuer
  for any drill; production allows 5 duplicate certs per domain per week.

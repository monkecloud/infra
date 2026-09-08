variable "xoa_url" {
  description = "Xen Orchestra websocket URL."
  type        = string
  default     = "ws://localhost:80"
}

variable "xoa_username" {
  description = "Xen Orchestra login."
  type        = string
}

variable "xoa_password" {
  description = "Xen Orchestra password."
  type        = string
  sensitive   = true
}

variable "template_name" {
  description = <<-EOT
    Name-label of the XCP-ng template every k3s node is cloned from.

    NOT built by this Terraform — see ../README.md ("Prerequisites").

    **A stock Ubuntu 24.04 cloud image is sufficient.** Import the official image into
    XCP-ng as a template and point this at it. Cloud-init installs the pinned k3s version
    (see k3s_version) plus open-iscsi and nfs-common on first boot, so nothing has to be
    baked in and there is no custom image to maintain.

    `tamarin-k3s-base` is the pre-baked variant that exists today. It boots faster because
    k3s is already installed, and is otherwise equivalent — keep using it while it exists,
    but do not rebuild it if it is lost.
  EOT
  type        = string
  default     = "tamarin-k3s-base"
}

variable "network_name" {
  description = "Name-label of the pool network the nodes attach to."
  type        = string
  default     = "pool-eth0"
}

variable "nodes" {
  description = <<-EOT
    One entry per physical XCP-ng host. Exactly one k3s VM is pinned to each host via
    affinity_host — the whole design assumes no two k3s VMs share a hypervisor.

    memory_max is per-host because the hosts are NOT uniform: tamarin-02/03/04 have
    ~15.9GiB of RAM, tamarin-05 has ~19.9GiB. Values below are host memory-total minus
    dom0's static-max minus ~1GiB of headroom.

    sr_id is a UUID rather than a name because three of the four hosts name their local
    SR "Local storage" — the label is not unique pool-wide. See ../README.md for the
    xe command that lists them.
  EOT

  type = map(object({
    xcp_host     = string
    sr_id        = string
    ip           = string
    mac          = string
    memory_max   = number
    cluster_init = optional(bool, false)
  }))

  default = {
    "k3s-tamarin-02" = {
      xcp_host   = "tamarin-02"
      sr_id      = "d623db9c-0385-5a99-a37d-41dcf5acd1e7"
      ip         = "192.168.2.101"
      mac        = "02:00:00:00:00:01"
      memory_max = 14495514624
    }
    "k3s-tamarin-03" = {
      xcp_host     = "tamarin-03"
      sr_id        = "3c2711f7-cd15-3216-f362-566a3c349c5d"
      ip           = "192.168.2.102"
      mac          = "02:00:00:00:00:02"
      memory_max   = 14495514624
      cluster_init = true
    }
    "k3s-tamarin-04" = {
      xcp_host   = "tamarin-04"
      sr_id      = "07f4a924-c3ba-ede3-b6a1-897d64e289a8"
      ip         = "192.168.2.103"
      mac        = "02:00:00:00:00:03"
      memory_max = 14495514624
    }
    "k3s-tamarin-05" = {
      xcp_host   = "tamarin-05"
      sr_id      = "0bf45cda-d131-eee9-1bae-5d4b5d524ba6"
      ip         = "192.168.2.104"
      mac        = "02:00:00:00:00:04"
      memory_max = 17716740096
    }
  }

  validation {
    condition     = length([for n in var.nodes : n if try(n.cluster_init, false)]) == 1
    error_message = "Exactly one node must have cluster_init = true."
  }
}

variable "vcpus" {
  description = "vCPUs per node. All four hosts are 4-core and run exactly one guest."
  type        = number
  default     = 4
}

variable "os_disk_size" {
  description = "OS disk size in bytes. Must be >= the template's OS disk (20GiB)."
  type        = number
  default     = 21474836480 # 20 GiB
}

variable "data_disk_size" {
  description = <<-EOT
    Second disk, in bytes. Reserved for Longhorn, left unformatted. Longhorn is not
    installed today (nothing needs it yet), but the disk is provisioned up front so
    adding it later doesn't require another rolling VM shutdown.
  EOT
  type        = number
  default     = 32212254720 # 30 GiB
}

variable "memory_min" {
  description = <<-EOT
    Dynamic-minimum memory in bytes — the floor XCP-ng may balloon a node down to.

    Only matters if a host ever runs a second guest; with one VM per host it stays at
    memory_max in practice.
  EOT
  type        = number
  default     = 6442450944 # 6 GiB
}

variable "node_cidr" {
  description = <<-EOT
    Subnet the nodes' addresses fall in. The provider uses this to decide when a VM has
    finished booting — it waits until the guest reports an address inside this range.
  EOT
  type        = string
  default     = "192.168.2.0/24"
}

variable "api_vip" {
  description = <<-EOT
    Floating address for the Kubernetes API, served by kube-vip (installed in layer 20).

    Layer 10 only needs it so the value can be baked into each node's
    /etc/rancher/k3s/config.yaml as a tls-san BEFORE k3s first starts. The apiserver
    serving certificate is generated on first boot; a SAN added afterwards requires
    regenerating that cert and rolling k3s across every node.

    Must sit outside the DHCP pool (which is .10-.99) and outside the node addresses.
  EOT
  type        = string
  default     = "192.168.2.201"
}

variable "gateway" {
  description = "Default gateway for the node static IPs."
  type        = string
  default     = "192.168.2.1"
}

variable "nameservers" {
  description = "DNS servers for the nodes."
  type        = list(string)
  default     = ["192.168.2.1", "207.164.234.193"]
}

variable "k3s_token" {
  description = <<-EOT
    Shared k3s cluster join token. Leave null to generate a fresh one (the right choice
    for a from-scratch rebuild). Set it only to match an existing cluster — e.g. adding
    tamarin-01's node back to the live cluster rather than rebuilding everything.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "root_password" {
  description = <<-EOT
    Root password set by cloud-init on each node.

    No default on purpose — this repo is the rebuild path, and a real password must not sit
    in it in plaintext. Set it in terraform.tfvars, which is gitignored.
  EOT
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = <<-EOT
    Optional SSH public key added to root's authorized_keys on every node.

    Strongly recommended: without it every later step (kubeconfig fetch, Garage layout
    bootstrap, ad-hoc debugging) falls back to password auth, which needs the
    SSH_ASKPASS workaround because this machine has no sshpass/expect.
  EOT
  type        = string
  default     = null
}

variable "kubeconfig_output_path" {
  description = "Where to write the fetched admin kubeconfig. Layers 20 and 30 read this path."
  type        = string
  default     = "../kubeconfig"
}

variable "k3s_version" {
  description = <<-EOT
    k3s version installed on first boot when the image does not already ship it.

    The `tamarin-k3s-base` template has k3s baked in, so this is normally unused — it exists
    so the template is not a hard dependency. If the template is ever lost, point `10-vms` at
    a stock Ubuntu 24.04 cloud image and cloud-init installs this version instead.

    Pinned rather than "latest" so a rebuild reproduces the cluster it is meant to replace,
    and so all four nodes agree.
  EOT
  type        = string
  default     = "v1.36.4+k3s1"
}

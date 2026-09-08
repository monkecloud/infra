data "xenorchestra_template" "k3s_base" {
  name_label = var.template_name
}

data "xenorchestra_network" "pool" {
  name_label = var.network_name
}

data "xenorchestra_host" "hosts" {
  for_each   = toset([for n in var.nodes : n.xcp_host])
  name_label = each.key
}

resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

locals {
  k3s_token = coalesce(var.k3s_token, random_password.k3s_token.result)

  init_node_name = one([for name, n in var.nodes : name if n.cluster_init])
  init_node      = var.nodes[local.init_node_name]
  joiner_nodes   = { for name, n in var.nodes : name => n if !n.cluster_init }

  # Every joiner points at the init node's apiserver. If that node is ever rebuilt
  # from scratch the others need to be re-pointed at whichever node takes over.
  server_ip = local.init_node.ip

  node_ips = { for name, n in var.nodes : name => n.ip }
}

# The VM's own MAC is what network-config matches on, so it has to be pinned rather
# than left for XO to generate.
resource "xenorchestra_vm" "init" {
  name_label       = local.init_node_name
  name_description = "k3s server (cluster-init node) — managed by Terraform"
  template         = data.xenorchestra_template.k3s_base.id
  affinity_host    = data.xenorchestra_host.hosts[local.init_node.xcp_host].id

  cpus       = var.vcpus
  memory_max = local.init_node.memory_max
  memory_min = var.memory_min

  cloud_config = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    hostname       = local.init_node_name
    cluster_init   = true
    server_ip      = local.server_ip
    k3s_token      = local.k3s_token
    root_password  = var.root_password
    ssh_public_key = var.ssh_public_key
    api_vip        = var.api_vip
    k3s_version    = var.k3s_version
  })
  cloud_network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tftpl", {
    mac         = local.init_node.mac
    ip          = local.init_node.ip
    prefix      = 24
    gateway     = var.gateway
    nameservers = join(", ", var.nameservers)
  })

  network {
    network_id  = data.xenorchestra_network.pool.id
    mac_address = local.init_node.mac

    # There is no wait_for_ip on this resource; declaring the CIDR the node should land
    # in is what makes the provider block until the guest actually reports an address.
    expected_ip_cidr = var.node_cidr
  }

  # Disks map positionally onto the template's two disks.
  disk {
    sr_id      = local.init_node.sr_id
    name_label = "${local.init_node_name}-os"
    size       = var.os_disk_size
  }

  disk {
    sr_id      = local.init_node.sr_id
    name_label = "${local.init_node_name}-longhorn-data"
    size       = var.data_disk_size
  }

  tags = ["k3s", "terraform"]

  lifecycle {
    # Recreating a node is a deliberate, disruptive act (it drops an etcd member);
    # never let an incidental template or cloud-init diff trigger one silently.
    prevent_destroy = true
  }
}

resource "xenorchestra_vm" "joiner" {
  for_each = local.joiner_nodes

  name_label       = each.key
  name_description = "k3s server (joins ${local.init_node_name}) — managed by Terraform"
  template         = data.xenorchestra_template.k3s_base.id
  affinity_host    = data.xenorchestra_host.hosts[each.value.xcp_host].id

  cpus       = var.vcpus
  memory_max = each.value.memory_max
  memory_min = var.memory_min

  cloud_config = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    hostname       = each.key
    cluster_init   = false
    server_ip      = local.server_ip
    k3s_token      = local.k3s_token
    root_password  = var.root_password
    ssh_public_key = var.ssh_public_key
    api_vip        = var.api_vip
    k3s_version    = var.k3s_version
  })
  cloud_network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tftpl", {
    mac         = each.value.mac
    ip          = each.value.ip
    prefix      = 24
    gateway     = var.gateway
    nameservers = join(", ", var.nameservers)
  })

  network {
    network_id  = data.xenorchestra_network.pool.id
    mac_address = each.value.mac

    expected_ip_cidr = var.node_cidr
  }

  disk {
    sr_id      = each.value.sr_id
    name_label = "${each.key}-os"
    size       = var.os_disk_size
  }

  disk {
    sr_id      = each.value.sr_id
    name_label = "${each.key}-longhorn-data"
    size       = var.data_disk_size
  }

  tags = ["k3s", "terraform"]

  # The init node has to have finished bootstrapping etcd before anyone joins.
  depends_on = [xenorchestra_vm.init]

  lifecycle {
    prevent_destroy = true
  }
}

# Pull the admin kubeconfig off the init node and rewrite its server address, so layers
# 20 and 30 have something to authenticate with. Re-run with:
#   terraform apply -replace=null_resource.kubeconfig
resource "null_resource" "kubeconfig" {
  depends_on = [xenorchestra_vm.init, xenorchestra_vm.joiner]

  triggers = {
    server_ip = local.server_ip
    node_ips  = join(",", values(local.node_ips))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      "${abspath(path.module)}/../scripts/fetch-kubeconfig.sh" \
        "${local.server_ip}" \
        "${abspath("${path.module}/${var.kubeconfig_output_path}")}"
    EOT

    environment = {
      NODE_ROOT_PASSWORD = var.root_password
    }
  }
}

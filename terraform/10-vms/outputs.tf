output "node_ips" {
  description = "Node name to static IP."
  value       = local.node_ips
}

output "init_node" {
  description = "Node that ran K3S_CLUSTER_INIT; the join target for every other node."
  value       = local.init_node_name
}

output "server_ip" {
  description = "apiserver address the other nodes joined against."
  value       = local.server_ip
}

output "k3s_token" {
  description = "Shared cluster join token. Needed to add any future node (e.g. tamarin-01)."
  value       = local.k3s_token
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Admin kubeconfig written by the fetch step. Feed this to layers 20 and 30."
  value       = abspath("${path.module}/${var.kubeconfig_output_path}")
}

output "api_vip" {
  description = <<-EOT
    Control-plane VIP baked into every node's tls-san. Nothing answers on it until
    layer 20 installs kube-vip; until then use a node IP.
  EOT
  value       = var.api_vip
}

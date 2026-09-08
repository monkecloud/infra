provider "xenorchestra" {
  # XO runs in Docker on dt2 on port 80; the provider speaks the XO websocket API,
  # not the REST API, so this is ws:// (not http://).
  url      = var.xoa_url
  username = var.xoa_username
  password = var.xoa_password
  insecure = true
}

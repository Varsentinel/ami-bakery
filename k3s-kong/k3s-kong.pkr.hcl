packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())

  # Ubuntu publishes separate AMIs per architecture, and Graviton needs a
  # Graviton instance type.
  ami_arch      = var.architecture == "arm64" ? "arm64" : "amd64"
  ec2_arch      = var.architecture == "arm64" ? "arm64" : "x86_64"
  default_itype = var.architecture == "arm64" ? "t4g.large" : "t3.large"
  instance_type = var.instance_type != "" ? var.instance_type : local.default_itype

  ami_name = "${var.ami_name_prefix}-${replace(var.k3s_version, "+", "-")}-${local.ami_arch}-${local.timestamp}"

  tags = merge(
    {
      Name          = local.ami_name
      BuiltBy       = "packer"
      BuiltOn       = timestamp()
      SourceRepo    = "ami-bakery/k3s-kong"
      K3sVersion    = var.k3s_version
      KongChart     = var.kong_chart_version
      Architecture  = local.ami_arch
      UbuntuRelease = var.ubuntu_release
    },
    var.extra_tags,
  )
}

source "amazon-ebs" "k3s-kong" {
  region        = var.aws_region
  instance_type = local.instance_type
  ssh_username  = "ubuntu"

  ami_name        = local.ami_name
  ami_description = "Single-node k3s ${var.k3s_version} (Traefik disabled) with Kong Gateway ${var.kong_chart_version} serving ingress on :80/:443"
  ami_regions     = var.ami_regions
  ami_users       = var.ami_users

  # Instances launched from this AMI require IMDSv2.
  imds_support = "v2.0"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd*/ubuntu-${var.ubuntu_release}-${local.ami_arch}-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = local.ec2_arch
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
    encrypted             = false
  }

  # Build instance placement.
  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip_address
  ssh_interface               = var.ssh_interface

  # The build instance itself only ever needs inbound SSH; Packer manages a
  # temporary security group for that. Port 443 on the *baked* image is handled
  # by ufw + whatever security group the launched instance gets.
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  ssh_timeout               = "10m"
  ssh_clear_authorized_keys = true

  tags          = local.tags
  snapshot_tags = local.tags
  run_tags      = { Name = "packer-${local.ami_name}" }
}

build {
  name    = "k3s-kong"
  sources = ["source.amazon-ebs.k3s-kong"]

  # Config files, Helm values and the first-boot unit.
  provisioner "file" {
    source      = "${path.root}/files/"
    destination = "/tmp/bake/"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "ARCH=${local.ami_arch}",
      "K3S_VERSION=${var.k3s_version}",
      "KONG_CHART_VERSION=${var.kong_chart_version}",
      "KONG_NAMESPACE=${var.kong_namespace}",
      "HELM_VERSION=${var.helm_version}",
      "VALIDATE_BUILD=${var.validate_build}",
      "ENABLE_UFW=${var.enable_ufw}",
      "FIREWALL_TCP_PORTS=${join(" ", var.firewall_tcp_ports)}",
    ]
    scripts = [
      "${path.root}/scripts/00-base.sh",
      "${path.root}/scripts/10-install-k3s.sh",
      "${path.root}/scripts/20-install-kong.sh",
      "${path.root}/scripts/30-validate.sh",
      "${path.root}/scripts/40-reset-k3s.sh",
      "${path.root}/scripts/50-firewall.sh",
      "${path.root}/scripts/99-cleanup.sh",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      k3s_version        = var.k3s_version
      kong_chart_version = var.kong_chart_version
      architecture       = local.ami_arch
    }
  }
}

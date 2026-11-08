# ---------------------------------------------------------------------------
# AWS / build-instance settings
# ---------------------------------------------------------------------------

variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "Region the AMI is built in."
}

variable "ami_regions" {
  type        = list(string)
  default     = []
  description = "Extra regions to copy the finished AMI to."
}

variable "ami_users" {
  type        = list(string)
  default     = []
  description = "AWS account IDs to share the finished AMI with."
}

variable "ami_name_prefix" {
  type        = string
  default     = "k3s-kong"
  description = "AMI name prefix; a UTC timestamp is appended."
}

variable "architecture" {
  type        = string
  default     = "amd64"
  description = "Target architecture: amd64 or arm64."

  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "The architecture variable must be \"amd64\" or \"arm64\"."
  }
}

variable "instance_type" {
  type        = string
  default     = ""
  description = "Build instance type. Empty picks t3.large (amd64) or t4g.large (arm64). k3s + Kong needs >= 2 vCPU / 4 GiB to converge quickly."
}

variable "ubuntu_release" {
  type        = string
  default     = "noble-24.04"
  description = "Ubuntu release to use as the source AMI, e.g. noble-24.04 or jammy-22.04."
}

variable "root_volume_size" {
  type        = number
  default     = 20
  description = "Root EBS volume size in GiB. The preloaded container images need ~4 GiB."
}

variable "root_volume_type" {
  type        = string
  default     = "gp3"
  description = "Root EBS volume type."
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC for the build instance. Empty uses the account default VPC."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet for the build instance. Empty lets Packer pick one in the default VPC."
}

variable "associate_public_ip_address" {
  type        = bool
  default     = true
  description = "Give the build instance a public IP. Set false when building in a private subnet that reaches the internet via NAT, and set ssh_interface accordingly."
}

variable "ssh_interface" {
  type        = string
  default     = "public_ip"
  description = "How Packer connects: public_ip, private_ip, public_dns, private_dns or session_manager."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to the AMI and its snapshots."
}

# ---------------------------------------------------------------------------
# k3s / Kong versions
# ---------------------------------------------------------------------------

variable "k3s_version" {
  type        = string
  default     = "v1.37.2+k3s1"
  description = "Exact k3s release to install (INSTALL_K3S_VERSION)."
}

variable "kong_chart_version" {
  type        = string
  default     = "3.4.1"
  description = "Version of the kong/kong Helm chart to render into the baked manifests."
}

variable "kong_namespace" {
  type        = string
  default     = "kong"
  description = "Namespace Kong Gateway is deployed into."
}

variable "helm_version" {
  type        = string
  default     = "v3.22.1"
  description = "Helm version used at build time to render the Kong chart. Helm is removed from the image afterwards."
}

# ---------------------------------------------------------------------------
# Image behaviour
# ---------------------------------------------------------------------------

variable "firewall_tcp_ports" {
  type        = list(string)
  default     = ["22", "80", "443", "6443"]
  description = "TCP ports ufw accepts on the baked image. 443 is the Kong HTTPS proxy, 6443 the Kubernetes API. Drop 6443 if the API server must not be reachable from outside the host."
}

variable "enable_ufw" {
  type        = bool
  default     = true
  description = "Configure and enable ufw with k3s-safe rules. When false, ingress filtering is left entirely to security groups."
}

variable "validate_build" {
  type        = bool
  default     = true
  description = "Boot k3s during the build and assert Kong answers on :443 before snapshotting. Leave on: this is also what warms the container image cache."
}

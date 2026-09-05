# ─── Common ───────────────────────────────────────────────────────────────────
variable "environment" {
  description = "Deployment environment (e.g. prod, staging, dev)"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource naming"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (used for subnet and SG discovery tags)"
  type        = string
}

# ─── VPC ──────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "VPC CIDR must be a valid IPv4 network."
  }
}

variable "enable_dns_support" {
  description = "Enable DNS support in VPC"
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in VPC"
  type        = bool
  default     = true
}

# ─── Subnets ──────────────────────────────────────────────────────────────────
variable "subnet_layout" {
  description = "Stable AZ keys with separate load-balancer, worker, and isolated data CIDRs"
  type = map(object({
    availability_zone = string
    public_cidr       = string
    private_cidr      = string
    data_cidr         = string
  }))
  validation {
    condition     = length(var.subnet_layout) >= 2 && length(distinct([for subnet in values(var.subnet_layout) : subnet.availability_zone])) == length(var.subnet_layout)
    error_message = "Use at least two distinct availability zones with stable map keys."
  }
  validation {
    condition     = alltrue(flatten([for subnet in values(var.subnet_layout) : [for cidr in [subnet.public_cidr, subnet.private_cidr, subnet.data_cidr] : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) <= 24, false)]]))
    error_message = "Subnets must be valid IPv4 CIDRs, /24 or larger; budget IPs for nodes, pods, endpoints and load balancers."
  }
}

# ─── VPC Endpoints ────────────────────────────────────────────────────────────
variable "enable_vpc_endpoints" {
  description = "Create private AWS service endpoints alongside NAT egress"
  type        = bool
  default     = true
}

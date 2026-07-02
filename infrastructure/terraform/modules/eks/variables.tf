# ─── Common ───────────────────────────────────────────────────────────────────
variable "environment" {
  description = "Deployment environment"
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

# ─── EKS Cluster ──────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "cluster_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "endpoint_private_access" {
  description = "Enable private API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API endpoint"
  type        = bool
  default     = true
}

# ─── Stable Node Group (On-Demand) ───────────────────────────────────────────
variable "node_instance_type" {
  description = "EC2 instance type for stable worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of stable nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of stable nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of stable nodes"
  type        = number
  default     = 4
}

# ─── Karpenter ────────────────────────────────────────────────────────────────
variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.1.1"
}

# ─── Network (from remote state) ─────────────────────────────────────────────
variable "remote_state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
}

variable "network_remote_state_key" {
  description = "S3 key for the network layer state"
  type        = string
  default     = "prod/network/terraform.tfstate"
}

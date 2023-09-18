variable "name" {
  description = "Name of the VPC and EKS Cluster"
  default     = "cnpg-on-eks"
  type        = string
}

variable "region" {
  description = "Region"
  type        = string
  default     = "us-west-2"
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  default     = "1.25"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  default     = "10.1.0.0/16"
  type        = string
}

variable "aws_access_key" {
  description = "The AWS Access Key for authentication"
  type        = string
  default     = ""
}

variable "aws_secret_key" {
  description = "The AWS Secret Key for authentication"
  type        = string
  default     = ""
}

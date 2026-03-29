variable "cluster_name" { type = string }
variable "k8s_version" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "node_instance_type" { type = string }
variable "node_min" { type = number }
variable "node_max" { type = number }
variable "node_desired" { type = number }
variable "environment" { type = string }
variable "name_suffix" { type = string, default = "" }

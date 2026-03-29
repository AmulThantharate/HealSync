variable "environment"       { type = string }
variable "vpc_id"            { type = string }
variable "subnet_ids"        { type = list(string) }
variable "instance_class"    { type = string }
variable "db_name"           { type = string }
variable "db_username"       { type = string }
variable "db_password"       { type = string; sensitive = true }
variable "eks_sg_id"         { type = string }
variable "aws_region"        { type = string }
variable "name_suffix"       { type = string, default = "" }

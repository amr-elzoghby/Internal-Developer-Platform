output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = values(aws_subnet.public)[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = values(aws_subnet.private)[*].id
}



output "data_subnet_ids" {
  value = values(aws_subnet.data)[*].id
}
output "data_subnet_cidrs" {
  value = [for subnet in values(var.subnet_layout) : subnet.data_cidr]
}
output "private_subnet_cidrs" {
  value = [for subnet in values(var.subnet_layout) : subnet.private_cidr]
}
output "public_subnet_cidrs" {
  value = [for subnet in values(var.subnet_layout) : subnet.public_cidr]
}

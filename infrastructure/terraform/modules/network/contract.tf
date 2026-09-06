# Consumers receive only this non-secret versioned contract, never an entire state snapshot.
resource "aws_ssm_parameter" "contract" {
  name = "/idp/${var.environment}/network"
  type = "String"
  value = jsonencode({
    schema_version       = 1
    environment          = var.environment
    cluster_name         = var.cluster_name
    vpc_id               = aws_vpc.main.id
    vpc_cidr             = aws_vpc.main.cidr_block
    private_subnet_ids   = values(aws_subnet.private)[*].id
    public_subnet_ids    = values(aws_subnet.public)[*].id
    data_subnet_ids      = values(aws_subnet.data)[*].id
    private_subnet_cidrs = [for subnet in values(var.subnet_layout) : subnet.private_cidr]
    public_subnet_cidrs  = [for subnet in values(var.subnet_layout) : subnet.public_cidr]
    data_subnet_cidrs    = [for subnet in values(var.subnet_layout) : subnet.data_cidr]
  })
  lifecycle { prevent_destroy = true }
}

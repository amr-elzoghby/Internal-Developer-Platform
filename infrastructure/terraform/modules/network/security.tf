# ─── Security Group (VPC Endpoints) ──────────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name        = "${var.name_prefix}-vpc-endpoints-sg"
  description = "Allow HTTPS from worker subnets to private AWS endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for subnet in values(var.subnet_layout) : subnet.private_cidr]
  }

  # Interface endpoints only accept connections; stateful replies need no outbound rule.


  tags = {
    Name = "${var.name_prefix}-vpc-endpoints-sg"
  }
}

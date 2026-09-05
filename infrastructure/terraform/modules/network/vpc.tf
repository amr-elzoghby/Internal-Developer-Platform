# ─── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = alltrue([for subnet in local.subnet_ranges : subnet.start >= local.vpc_range.start && subnet.end <= local.vpc_range.end]) && alltrue(flatten([for i, left in local.subnet_ranges : [for j, right in local.subnet_ranges : i == j || left.end < right.start || right.end < left.start]]))
      error_message = "All public, worker and data subnets must fit inside the VPC and must not overlap."
    }
  }

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# ─── Public Subnets ───────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  for_each = var.subnet_layout

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.public_cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.name_prefix}-public-${each.key}"
    Tier                                        = "Public"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ─── Private Subnets ──────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  for_each = var.subnet_layout

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.private_cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.name_prefix}-private-${each.key}"
    Tier                                        = "Private"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

# ─── Internet Gateway ─────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ─── Public Route Table ───────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = var.subnet_layout

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# ─── Private Route Table ──────────────────────────────────────────────────────
resource "aws_route_table" "private" {
  for_each = var.subnet_layout
  vpc_id   = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.private_egress[each.key].id
  }

  tags = {
    Name = "${var.name_prefix}-private-${each.value.availability_zone}-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = var.subnet_layout

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# One NAT per AZ provides public registry/chart and AWS API access for private
# workers without cross-AZ egress dependence. Interface endpoints keep AWS
# service traffic private; NAT still has an hourly and processing cost.
resource "aws_eip" "private_egress" {
  for_each = var.subnet_layout
  domain   = "vpc"
}

resource "aws_nat_gateway" "private_egress" {
  for_each      = var.subnet_layout
  allocation_id = aws_eip.private_egress[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${var.name_prefix}-nat-${each.value.availability_zone}" }
}

# Data subnets have no internet default route and are never worker candidates.
resource "aws_subnet" "data" {
  for_each                = var.subnet_layout
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.data_cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-data-${each.key}", Tier = "Data" }
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-data-isolated" }
}

resource "aws_route_table_association" "data" {
  for_each       = var.subnet_layout
  subnet_id      = aws_subnet.data[each.key].id
  route_table_id = aws_route_table.data.id
}

locals {
  subnet_cidrs = flatten([for subnet in values(var.subnet_layout) : [subnet.public_cidr, subnet.private_cidr, subnet.data_cidr]])
  subnet_ranges = [for cidr in local.subnet_cidrs : {
    start = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
    end   = sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  }]
  vpc_range = {
    start = sum([for i, octet in split(".", cidrhost(var.vpc_cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
    end   = sum([for i, octet in split(".", cidrhost(var.vpc_cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  }
}

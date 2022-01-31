data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  subnet_cidr = cidrsubnets(var.cidr, 4, 4, 4, 4)
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Network = "public"
  }
}

resource "aws_route_table" "private_rt" {
  count  = var.az
  vpc_id = aws_vpc.vpc.id

  tags = {
    Network = "private"
  }
}

resource "aws_eip" "nat_eip" {
  count = var.az
  vpc   = true
}

resource "aws_subnet" "public_subnet" {
  count                   = var.az
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = local.subnet_cidr[count.index]
  vpc_id                  = aws_vpc.vpc.id

  tags = {
    Name                     = "${var.cluster_name}_public_subnet_${sum([count.index, 1])}"
    "kubernetes.io/role/elb" = 1
  }
}

resource "aws_subnet" "private_subnet" {
  count                   = var.az
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = local.subnet_cidr[sum([count.index, var.az])]
  vpc_id                  = aws_vpc.vpc.id

  tags = {
    Name                                        = "${var.cluster_name}_private_subnet_${sum([count.index, 1])}"
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_nat_gateway" "nat_gw" {
  count         = var.az
  depends_on    = [aws_eip.nat_eip, aws_internet_gateway.igw]
  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.public_subnet[count.index].id

  tags = {
    Name = "${var.cluster_name}_nat_gw_${sum([count.index, 1])}"
  }
}

resource "aws_route" "public_r" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route" "private_r" {
  count                  = var.az
  route_table_id         = aws_route_table.private_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gw[count.index].id
}

resource "aws_route_table_association" "public_subnet_rt_a" {
  count          = var.az
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_subnet_rt_a" {
  count          = var.az
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_rt[count.index].id
}

resource "aws_security_group" "cluster_sg" {
  description = "Cluster communication with worker nodes"
  vpc_id      = aws_vpc.vpc.id
}

# ==========================================
# 1. VPC & Networking
# ==========================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "kidhackapp-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "kidhackapp-igw" }
}

# Subnets
resource "aws_subnet" "public_2a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.0.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "kidhackapp-public-2a" }
}

resource "aws_subnet" "public_2c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.1.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "kidhackapp-public-2c" }
}

resource "aws_subnet" "web_private_2a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.10.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "kidhackapp-web-private-2a" }
}

resource "aws_subnet" "web_private_2c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.11.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "kidhackapp-web-private-2c" }
}

resource "aws_subnet" "was_private_2a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.20.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "kidhackapp-was-private-2a" }
}

resource "aws_subnet" "was_private_2c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.21.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "kidhackapp-was-private-2c" }
}

resource "aws_subnet" "db_private_2a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.30.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "kidhackapp-db-private-2a" }
}

resource "aws_subnet" "db_private_2c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.31.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "kidhackapp-db-private-2c" }
}

# Elastic IPs & Multi-AZ NAT Gateways
resource "aws_eip" "nat_2a" {
  domain = "vpc"
  tags   = { Name = "kidhackapp-nat-eip-2a" }
}

resource "aws_eip" "nat_2c" {
  domain = "vpc"
  tags   = { Name = "kidhackapp-nat-eip-2c" }
}

resource "aws_nat_gateway" "nat_2a" {
  allocation_id = aws_eip.nat_2a.id
  subnet_id     = aws_subnet.public_2a.id
  tags          = { Name = "kidhackapp-nat-2a" }
}

resource "aws_nat_gateway" "nat_2c" {
  allocation_id = aws_eip.nat_2c.id
  subnet_id     = aws_subnet.public_2c.id
  tags          = { Name = "kidhackapp-nat-2c" }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "kidhackapp-public-rt" }
}

resource "aws_route_table" "private_2a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2a.id
  }
  tags = { Name = "kidhackapp-private-rt-2a" }
}

resource "aws_route_table" "private_2c" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2c.id
  }
  tags = { Name = "kidhackapp-private-rt-2c" }
}

# DB 전용 라우트 테이블 — 0.0.0.0/0 (NAT) 경로가 없다.
#
# RDS / DocumentDB / ElastiCache 는 아웃바운드 인터넷이 필요 없다.
# 자동 백업과 스냅샷은 이 VPC 의 라우트 테이블이 아니라 AWS 내부 경로로 나가므로,
# NAT 경로를 빼도 백업은 그대로 동작한다.
#
# AZ 별로 나누지 않은 이유: NAT 경로가 없으면 AZ 에 종속되는 라우트 자체가 없다.
# (private_2a/2c 를 둘로 나눈 건 오직 AZ 별 NAT 을 가리키기 위해서였다)
# 남는 건 local 과 S3 게이트웨이 엔드포인트뿐이고 둘 다 리전 단위라 하나면 충분하다.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "kidhackapp-db-rt" }
}

# Route Table Associations
resource "aws_route_table_association" "pub_2a" {
  subnet_id      = aws_subnet.public_2a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "pub_2c" {
  subnet_id      = aws_subnet.public_2c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "web_2a" {
  subnet_id      = aws_subnet.web_private_2a.id
  route_table_id = aws_route_table.private_2a.id
}
resource "aws_route_table_association" "was_2a" {
  subnet_id      = aws_subnet.was_private_2a.id
  route_table_id = aws_route_table.private_2a.id
}
resource "aws_route_table_association" "db_2a" {
  subnet_id      = aws_subnet.db_private_2a.id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "web_2c" {
  subnet_id      = aws_subnet.web_private_2c.id
  route_table_id = aws_route_table.private_2c.id
}
resource "aws_route_table_association" "was_2c" {
  subnet_id      = aws_subnet.was_private_2c.id
  route_table_id = aws_route_table.private_2c.id
}
resource "aws_route_table_association" "db_2c" {
  subnet_id      = aws_subnet.db_private_2c.id
  route_table_id = aws_route_table.db.id
}

# S3 Gateway Endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private_2a.id,
    aws_route_table.private_2c.id,
    aws_route_table.db.id
  ]
  tags = { Name = "kidhackapp-s3-endpoint" }
}

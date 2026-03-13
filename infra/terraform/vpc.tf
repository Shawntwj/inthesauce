# ─────────────────────────────────────────────────────────────────
# VPC + Subnets — models production network topology via LocalStack
# Teaches: CIDR math, subnet sizing, security groups, route tables
#
# NOTE: LocalStack free tier has partial EC2/VPC support. terraform plan
# will always work (and is the main learning tool). terraform apply may
# partially succeed — that's itself a learning moment about LocalStack
# free-tier limitations.
# ─────────────────────────────────────────────────────────────────

# ── VPC ──────────────────────────────────────────────────────────
resource "aws_vpc" "etrm" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "etrm-vpc"
    Environment = var.environment
    Purpose     = "ETRM sandbox network — models production VPC"
  }
}

# ── Subnets ──────────────────────────────────────────────────────
# Three tiers matching the Docker Compose network segmentation:
#   public  (10.0.1.0/24) — load balancers, NAT gateway
#   app     (10.0.2.0/24) — Go services, Redis
#   data    (10.0.3.0/24) — MSSQL, ClickHouse, MDM Postgres

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.etrm.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "etrm-public"
    Environment = var.environment
    Tier        = "public"
    Purpose     = "ALB, NAT gateway, bastion host"
  }
}

resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.etrm.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name        = "etrm-app"
    Environment = var.environment
    Tier        = "application"
    Purpose     = "Go services (trade-service, mdm-service), Redis"
  }
}

resource "aws_subnet" "data" {
  vpc_id            = aws_vpc.etrm.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name        = "etrm-data"
    Environment = var.environment
    Tier        = "data"
    Purpose     = "MSSQL, ClickHouse, MDM Postgres — no public access"
  }
}

# ── Internet Gateway ─────────────────────────────────────────────
# Only the public subnet gets internet access (via this IGW + route table)
resource "aws_internet_gateway" "etrm" {
  vpc_id = aws_vpc.etrm.id

  tags = {
    Name        = "etrm-igw"
    Environment = var.environment
  }
}

# ── Route Table (public subnet) ─────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.etrm.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.etrm.id
  }

  tags = {
    Name        = "etrm-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ──────────────────────────────────────────────

# App tier: allows inbound from public subnet (ALB), outbound to data tier
resource "aws_security_group" "app_tier" {
  name        = "etrm-app-tier"
  description = "Application tier — Go services, Redis"
  vpc_id      = aws_vpc.etrm.id

  # HTTP from public subnet (ALB → service)
  ingress {
    description = "HTTP from public subnet"
    from_port   = 8080
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public.cidr_block]
  }

  # Prometheus scrape from monitoring
  ingress {
    description = "Prometheus metrics scrape"
    from_port   = 8080
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.etrm.cidr_block]
  }

  # All outbound (services call databases, Kafka, external APIs)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "etrm-app-sg"
    Environment = var.environment
    Tier        = "application"
  }
}

# Data tier: allows inbound ONLY from app tier — no public access
resource "aws_security_group" "data_tier" {
  name        = "etrm-data-tier"
  description = "Data tier — databases (MSSQL, ClickHouse, Postgres). No public access."
  vpc_id      = aws_vpc.etrm.id

  # MSSQL from app tier only
  ingress {
    description     = "MSSQL from app tier"
    from_port       = 1433
    to_port         = 1433
    protocol        = "tcp"
    security_groups = [aws_security_group.app_tier.id]
  }

  # ClickHouse HTTP from app tier only
  ingress {
    description     = "ClickHouse HTTP from app tier"
    from_port       = 8123
    to_port         = 8123
    protocol        = "tcp"
    security_groups = [aws_security_group.app_tier.id]
  }

  # ClickHouse native TCP from app tier only
  ingress {
    description     = "ClickHouse native TCP from app tier"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.app_tier.id]
  }

  # Postgres from app tier only
  ingress {
    description     = "MDM Postgres from app tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_tier.id]
  }

  # Outbound: databases shouldn't initiate external connections
  # (allow VPC-internal only for replication, DNS)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.etrm.cidr_block]
  }

  tags = {
    Name        = "etrm-data-sg"
    Environment = var.environment
    Tier        = "data"
  }
}

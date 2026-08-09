# =============================================================================
# CAPA 1 · RED — VPC, Internet Gateway, subredes, NAT, route tables,
#                security groups y VPC endpoints
# =============================================================================
# Topología: VPC 10.0.0.0/16 en 2 AZs.
#   - Pública  1a 10.0.1.0/24  ┐  (solo NAT)
#   - Pública  1b 10.0.3.0/24  ┘
#   - Privada  1a 10.0.2.0/24  ┐  (Lambdas en VPC, DAX, RDS)
#   - Privada  1b 10.0.4.0/24  ┘
# NAT: 1 por zona. Route tables: 1 pública compartida + 2 privadas zonales = 3.
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# ----------------------------- Subredes --------------------------------------
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_public_a_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-a", Tier = "public" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_public_b_cidr
  availability_zone       = var.az_b
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-b", Tier = "public" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_private_a_cidr
  availability_zone = var.az_a
  tags              = { Name = "${var.project}-private-a", Tier = "private" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_private_b_cidr
  availability_zone = var.az_b
  tags              = { Name = "${var.project}-private-b", Tier = "private" }
}

# ------------------------- NAT Gateways + EIPs -------------------------------
resource "aws_eip" "nat_a" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${var.project}-eip-nat-a" }
}

resource "aws_eip" "nat_b" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${var.project}-eip-nat-b" }
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${var.project}-nat-a" }
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${var.project}-nat-b" }
}

# --------------------- Route table PÚBLICA (compartida) ----------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-rt-public" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# ------------------- Route tables PRIVADAS (una por zona) --------------------
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.a.id
  }

  tags = { Name = "${var.project}-rt-private-a" }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.b.id
  }

  tags = { Name = "${var.project}-rt-private-b" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

# =============================================================================
# Security Groups · patrón de cadena (menor privilegio)
#   SG-lambdas ─5432▶ SG-rds · ─8111▶ SG-dax · ─443▶ SG-endpoints / 0.0.0.0/0
# =============================================================================
resource "aws_security_group" "lambdas" {
  name        = "${var.project}-sg-lambdas"
  description = "Lambdas en VPC. Sin entradas (nadie inicia hacia una Lambda)."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-lambdas" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-sg-rds"
  description = "RDS PostgreSQL. Solo acepta 5432 desde SG-lambdas."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-rds" }
}

resource "aws_security_group" "dax" {
  name        = "${var.project}-sg-dax"
  description = "DAX. Solo acepta 8111 desde SG-lambdas."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-dax" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.project}-sg-endpoints"
  description = "Interface Endpoints. Solo acepta 443 desde SG-lambdas."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg-endpoints" }
}

# --- SG-lambdas · salidas ---
resource "aws_vpc_security_group_egress_rule" "lambdas_to_rds" {
  security_group_id            = aws_security_group.lambdas.id
  description                  = "PostgreSQL hacia RDS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id
}

resource "aws_vpc_security_group_egress_rule" "lambdas_to_dax" {
  security_group_id            = aws_security_group.lambdas.id
  description                  = "DAX hacia DAX"
  from_port                    = 8111
  to_port                      = 8111
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.dax.id
}

resource "aws_vpc_security_group_egress_rule" "lambdas_to_endpoints" {
  security_group_id            = aws_security_group.lambdas.id
  description                  = "HTTPS hacia Interface Endpoints"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.endpoints.id
}

resource "aws_vpc_security_group_egress_rule" "lambdas_to_internet" {
  security_group_id = aws_security_group.lambdas.id
  description       = "HTTPS a internet via NAT (pasarela de pago, APIs AWS sin endpoint)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- entradas ---
resource "aws_vpc_security_group_ingress_rule" "rds_from_lambdas" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL desde SG-lambdas"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambdas.id
}

resource "aws_vpc_security_group_ingress_rule" "dax_from_lambdas" {
  security_group_id            = aws_security_group.dax.id
  description                  = "DAX (8111) desde SG-lambdas"
  from_port                    = 8111
  to_port                      = 8111
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambdas.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_lambdas" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS (443) desde SG-lambdas"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambdas.id
}

# =============================================================================
# VPC Endpoints
#   - Gateway (S3, DynamoDB): GRATIS, asociados a las route tables privadas.
#   - Interface (Kinesis, CloudWatch Logs): opcionales (toggle), con costo/hora.
# =============================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_b.id]
  tags              = { Name = "${var.project}-vpce-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_b.id]
  tags              = { Name = "${var.project}-vpce-dynamodb" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : []

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-vpce-${each.value}" }
}

# =============================================================================
# CAPA 2 · DATOS — RDS PostgreSQL, DynamoDB, DAX y Timestream
# =============================================================================

# -----------------------------------------------------------------------------
# RDS PostgreSQL 16 · Single-AZ · subred privada 1a · autenticación IAM
# -----------------------------------------------------------------------------
# - Single-AZ en zona A: punto único de fallo ACEPTADO para financiero/admin.
# - iam_database_authentication_enabled = true → el usuario de app (ccs_app_bd)
#   se conecta con token IAM. Ese usuario lo crea la Lambda de bootstrap (capa 7).
# - Master por random_password (no Secrets Manager, coherente con auth IAM); se
#   entrega a la Lambda de bootstrap por variable de entorno en la capa 7.
# -----------------------------------------------------------------------------
resource "random_password" "rds_master" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  # Exige >=2 AZs aunque la instancia sea Single-AZ (se fija en zona A abajo).
  tags = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.project}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1" # obliga TLS; el codigo Go usa sslmode=require
  }

  tags = { Name = "${var.project}-pg16" }
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage
  storage_type      = "gp2" # gp2 = cubierto por la capa gratuita (20 GB)
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_master_username
  password = random_password.rds_master.result

  iam_database_authentication_enabled = true

  multi_az          = false
  availability_zone = var.az_a

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  apply_immediately          = true

  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "${var.project}-postgres" }
}

# -----------------------------------------------------------------------------
# DynamoDB · tabla de configuración de alertas (PK clienteId, on-demand)
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "config_alertas" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "clienteId"

  attribute {
    name = "clienteId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = var.dynamodb_table_name }
}

# -----------------------------------------------------------------------------
# DAX · caché frente a DynamoDB (2 nodos, uno por zona, puerto 8111)
# -----------------------------------------------------------------------------
resource "aws_dax_subnet_group" "main" {
  name       = "${var.project}-dax-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

data "aws_iam_policy_document" "dax_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dax.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dax" {
  name               = "${var.project}-dax-role"
  assume_role_policy = data.aws_iam_policy_document.dax_assume.json
  tags               = { Name = "${var.project}-dax-role" }
}

data "aws_iam_policy_document" "dax_ddb" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DescribeTable",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [aws_dynamodb_table.config_alertas.arn]
  }
}

resource "aws_iam_role_policy" "dax_ddb" {
  name   = "${var.project}-dax-ddb"
  role   = aws_iam_role.dax.id
  policy = data.aws_iam_policy_document.dax_ddb.json
}

resource "aws_dax_cluster" "main" {
  cluster_name       = "${var.project}-dax"
  node_type          = var.dax_node_type
  replication_factor = var.dax_replication_factor # 2 nodos: zona A y zona B
  iam_role_arn       = aws_iam_role.dax.arn

  subnet_group_name  = aws_dax_subnet_group.main.name
  security_group_ids = [aws_security_group.dax.id]

  server_side_encryption {
    enabled = true
  }

  tags = { Name = "${var.project}-dax" }
}

# -----------------------------------------------------------------------------
# DynamoDB · telemetría (REEMPLAZO de Timestream)
# -----------------------------------------------------------------------------
# Tabla SEPARADA de config-alertas: clave compuesta camionId (PK) + timestamp (SK)
# para consultas por rango temporal desde la Lambda de Estadísticas.
resource "aws_dynamodb_table" "telemetria" {
  name         = var.telemetria_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "camionId"
  range_key    = "timestamp"

  attribute {
    name = "camionId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "N"
  }

  tags = { Name = var.telemetria_table_name }
}

# -----------------------------------------------------------------------------
# Timestream · series de tiempo de telemetría
# -----------------------------------------------------------------------------
/*
resource "aws_timestreamwrite_database" "main" {
  database_name = var.timestream_db_name
  tags          = { Name = var.timestream_db_name }
}

resource "aws_timestreamwrite_table" "telemetria" {
  database_name = aws_timestreamwrite_database.main.database_name
  table_name    = var.timestream_table_name

  retention_properties {
    memory_store_retention_period_in_hours  = var.timestream_memory_retention_hours
    magnetic_store_retention_period_in_days = var.timestream_magnetic_retention_days
  }

  tags = { Name = var.timestream_table_name }
}
*/

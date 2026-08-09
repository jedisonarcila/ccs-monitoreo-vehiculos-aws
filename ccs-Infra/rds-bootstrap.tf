# =============================================================================
# CAPA 7 · BOOTSTRAP RDS — crea el rol IAM de Postgres + tabla usuarios
# -----------------------------------------------------------------------------
# La Lambda bootstrap-bd corre DENTRO de la VPC, se conecta a RDS con la
# credencial maestra y ejecuta el SQL idempotente. aws_lambda_invocation la
# dispara durante el apply. Se deja desplegada (ociosa cuesta $0).
#
# NOTA: define var.db_app_user, que también usa usuarios.tf. Ambos archivos van
# juntos en este paso.
# =============================================================================

variable "db_app_user" {
  description = "Rol de Postgres con autenticación IAM que usan las Lambdas."
  type        = string
  default     = "ccs_app_bd"
}

resource "aws_iam_role" "bootstrap_bd" {
  name               = "${var.project}-lambda-bootstrap-bd"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-bootstrap-bd" }
}

resource "aws_iam_role_policy_attachment" "bootstrap_bd_vpc" {
  role       = aws_iam_role.bootstrap_bd.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "bootstrap_bd" {
  function_name = "${var.project}-bootstrap-bd"
  role          = aws_iam_role.bootstrap_bd.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/bootstrap-bd/bootstrap-bd.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/bootstrap-bd/bootstrap-bd.zip")

  memory_size = 128
  timeout     = 60

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambdas.id]
  }

  environment {
    variables = {
      DB_HOST            = aws_db_instance.main.address
      DB_PORT            = tostring(aws_db_instance.main.port)
      DB_NAME            = aws_db_instance.main.db_name
      DB_MASTER_USER     = aws_db_instance.main.username
      DB_MASTER_PASSWORD = random_password.rds_master.result
      DB_APP_USER        = var.db_app_user
    }
  }

  tags = { Name = "${var.project}-bootstrap-bd" }
}

# Ejecuta el bootstrap durante el apply. Se re-ejecuta si cambia el código.
resource "aws_lambda_invocation" "bootstrap_bd" {
  function_name = aws_lambda_function.bootstrap_bd.function_name
  input         = jsonencode({})

  triggers = {
    codigo = aws_lambda_function.bootstrap_bd.source_code_hash
  }
}

output "bootstrap_resultado" {
  description = "Resultado de la ejecución del bootstrap de la BD."
  value       = aws_lambda_invocation.bootstrap_bd.result
}

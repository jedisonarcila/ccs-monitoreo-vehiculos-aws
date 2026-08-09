# =============================================================================
# CAPA 4 · CÓMPUTO — Lambda EMERGENCIA (primera pieza)
# -----------------------------------------------------------------------------
# Flujo: camión → MQTT ccs/<camionId>/emergencia → regla IoT → Lambda Emergencia
#        → lee config en DynamoDB → publica en SNS → email.
#
# El .zip lo compila el usuario con build.ps1 (Go → bootstrap → build-lambda-zip).
# =============================================================================

# -----------------------------------------------------------------------------
# SNS · topic de emergencias + suscripción por email (para pruebas)
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "emergencias" {
  name = "${var.project}-emergencias"
  tags = { Name = "${var.project}-emergencias" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.emergencias.arn
  protocol  = "email"
  endpoint  = var.email_emergencias
  # OJO: tras el apply, AWS envía un correo de confirmación. Hay que abrirlo y
  # hacer clic en "Confirm subscription" o no llegarán las notificaciones.
}

# -----------------------------------------------------------------------------
# IAM · rol de ejecución de la Lambda Emergencia
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "emergencia" {
  name               = "${var.project}-lambda-emergencia"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-emergencia" }
}

# ENIs para correr en la VPC + logs en CloudWatch (política gestionada de AWS).
resource "aws_iam_role_policy_attachment" "emergencia_vpc" {
  role       = aws_iam_role.emergencia.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Permisos específicos: leer config en DynamoDB + publicar en el topic SNS.
data "aws_iam_policy_document" "emergencia" {
  statement {
    sid       = "LeerConfigAlertas"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.config_alertas.arn]
  }
  statement {
    sid       = "PublicarEmergencias"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.emergencias.arn]
  }
}

resource "aws_iam_role_policy" "emergencia" {
  name   = "${var.project}-emergencia"
  role   = aws_iam_role.emergencia.id
  policy = data.aws_iam_policy_document.emergencia.json
}

# -----------------------------------------------------------------------------
# Lambda Emergencia
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "emergencia" {
  function_name = "${var.project}-emergencia"
  role          = aws_iam_role.emergencia.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/emergencia/emergencia.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/emergencia/emergencia.zip")

  memory_size = 128
  timeout     = 10

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambdas.id]
  }

  environment {
    variables = {
      TABLA_CONFIG      = aws_dynamodb_table.config_alertas.name
      TOPIC_EMERGENCIAS = aws_sns_topic.emergencias.arn
      DAX_ENDPOINT      = aws_dax_cluster.main.cluster_address
    }
  }

  tags = { Name = "${var.project}-emergencia" }
}

# -----------------------------------------------------------------------------
# Regla IoT · EMERGENCIA → Lambda
# El camión publica en ccs/<camionId>/emergencia con el JSON de emergencia.
# -----------------------------------------------------------------------------
resource "aws_iot_topic_rule" "emergencia" {
  name        = "${var.project}_emergencia"
  description = "Enruta las señales de emergencia a la Lambda Emergencia."
  enabled     = true
  sql         = "SELECT *, topic(2) AS camionId FROM '${var.iot_topic_prefix}/+/emergencia'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.emergencia.arn
  }

  tags = { Name = "${var.project}-rule-emergencia" }
}

# Permiso para que IoT invoque la Lambda.
resource "aws_lambda_permission" "iot_emergencia" {
  statement_id  = "AllowIoTInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.emergencia.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.emergencia.arn
}

# =============================================================================
# Lambda TELEMETRÍA — Kinesis → DynamoDB (fuera de la VPC)
# -----------------------------------------------------------------------------
# El servicio Lambda lee lotes del stream ccs-telemetria (event source mapping)
# y los entrega a esta función, que los guarda en la tabla ccs-telemetria.
# NO va en la VPC: solo lee Kinesis (vía el poller, con IAM) y escribe DynamoDB
# (endpoint público). Sin RDS ni DAX => sin ENIs ni NAT.
# =============================================================================

resource "aws_iam_role" "telemetria" {
  name               = "${var.project}-lambda-telemetria"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-telemetria" }
}

# Logs en CloudWatch (sin VPC).
resource "aws_iam_role_policy_attachment" "telemetria_basic" {
  role       = aws_iam_role.telemetria.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permisos: leer del stream de Kinesis + escribir en la tabla de telemetría.
data "aws_iam_policy_document" "telemetria" {
  statement {
    sid    = "LeerKinesis"
    effect = "Allow"
    actions = [
      "kinesis:GetRecords",
      "kinesis:GetShardIterator",
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.telemetria.arn]
  }
  statement {
    sid       = "ListarStreams"
    effect    = "Allow"
    actions   = ["kinesis:ListStreams"]
    resources = ["*"]
  }
  statement {
    sid       = "EscribirTelemetria"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
    resources = [aws_dynamodb_table.telemetria.arn]
  }
}

resource "aws_iam_role_policy" "telemetria" {
  name   = "${var.project}-telemetria"
  role   = aws_iam_role.telemetria.id
  policy = data.aws_iam_policy_document.telemetria.json
}

resource "aws_lambda_function" "telemetria" {
  function_name = "${var.project}-telemetria"
  role          = aws_iam_role.telemetria.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/telemetria/telemetria.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/telemetria/telemetria.zip")

  memory_size = 128
  timeout     = 30

  environment {
    variables = {
      TABLA_TELEMETRIA = aws_dynamodb_table.telemetria.name
    }
  }

  tags = { Name = "${var.project}-telemetria" }
}

# Enlace Kinesis → Lambda: el servicio Lambda hace polling del stream.
resource "aws_lambda_event_source_mapping" "telemetria" {
  event_source_arn  = aws_kinesis_stream.telemetria.arn
  function_name     = aws_lambda_function.telemetria.arn
  starting_position = "LATEST"
  batch_size        = var.kinesis_batch_size
}
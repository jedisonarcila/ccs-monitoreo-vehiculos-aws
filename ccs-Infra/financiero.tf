# =============================================================================
# PORTAL · Endpoint FINANCIERO — GET/POST /facturas (usa RDS con auth IAM)
# -----------------------------------------------------------------------------
# Mismo patrón que Usuarios: Lambda en la VPC, conecta a Postgres con token IAM.
# La tabla facturas la crea el bootstrap (ver nota al final de este archivo).
# Reutiliza api.main y authorizer.cognito de api.tf, y var.db_app_user de
# rds-bootstrap.tf. Autocontenido salvo esa dependencia (que ya existe).
# =============================================================================

resource "aws_iam_role" "financiero" {
  name               = "${var.project}-lambda-financiero"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-financiero" }
}

resource "aws_iam_role_policy_attachment" "financiero_vpc" {
  role       = aws_iam_role.financiero.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Permiso para conectarse a RDS con autenticación IAM como el rol de aplicación.
resource "aws_iam_role_policy" "financiero_rds" {
  name = "${var.project}-financiero-rds-connect"
  role = aws_iam_role.financiero.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/${var.db_app_user}"
    }]
  })
}

resource "aws_lambda_function" "financiero" {
  function_name = "${var.project}-financiero"
  role          = aws_iam_role.financiero.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/financiero/financiero.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/financiero/financiero.zip")

  memory_size = 128
  timeout     = 15

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambdas.id]
  }

  environment {
    variables = {
      DB_HOST     = aws_db_instance.main.address
      DB_PORT     = tostring(aws_db_instance.main.port)
      DB_NAME     = aws_db_instance.main.db_name
      DB_APP_USER = var.db_app_user
    }
  }

  # La tabla debe existir antes: espera al bootstrap.
  depends_on = [aws_lambda_invocation.bootstrap_bd]

  tags = { Name = "${var.project}-financiero" }
}

resource "aws_apigatewayv2_integration" "financiero" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.financiero.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_facturas" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /facturas"
  target             = "integrations/${aws_apigatewayv2_integration.financiero.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "post_facturas" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /facturas"
  target             = "integrations/${aws_apigatewayv2_integration.financiero.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "apigw_financiero" {
  statement_id  = "AllowAPIGatewayInvokeFinanciero"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.financiero.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# -----------------------------------------------------------------------------
# IMPORTANTE: la tabla facturas la crea el bootstrap. Agrega este bloque al SQL
# de ccs-lambdas/bootstrap-bd/main.go (antes de los GRANT finales), y recompila:
#
#   CREATE TABLE IF NOT EXISTS facturas (
#     id         SERIAL PRIMARY KEY,
#     cliente_id TEXT NOT NULL,
#     monto      NUMERIC(12,2) NOT NULL,
#     concepto   TEXT NOT NULL,
#     estado     TEXT NOT NULL DEFAULT 'pendiente',
#     creado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
#   );
#   GRANT SELECT, INSERT, UPDATE, DELETE ON facturas TO ccs_app_bd;
#
# (El bootstrap ya otorga USAGE/SELECT sobre las secuencias, así que el SERIAL
#  de facturas queda cubierto automáticamente.)
# -----------------------------------------------------------------------------

# =============================================================================
# PORTAL · Endpoint USUARIOS — GET/POST /usuarios (usa RDS con auth IAM)
# -----------------------------------------------------------------------------
# La Lambda corre en la VPC, se conecta a Postgres con token IAM (rds-db:connect)
# y opera la tabla usuarios. Depende del bootstrap (que crea el rol y la tabla).
# Reutiliza el API Gateway y el autorizador Cognito de api.tf. Autocontenido.
# =============================================================================

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "usuarios" {
  name               = "${var.project}-lambda-usuarios"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-usuarios" }
}

resource "aws_iam_role_policy_attachment" "usuarios_vpc" {
  role       = aws_iam_role.usuarios.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Permiso para conectarse a RDS con autenticación IAM como el rol de aplicación.
resource "aws_iam_role_policy" "usuarios_rds" {
  name = "${var.project}-usuarios-rds-connect"
  role = aws_iam_role.usuarios.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/${var.db_app_user}"
    }]
  })
}

resource "aws_lambda_function" "usuarios" {
  function_name = "${var.project}-usuarios"
  role          = aws_iam_role.usuarios.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/usuarios/usuarios.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/usuarios/usuarios.zip")

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

  # El rol y la tabla deben existir antes: espera al bootstrap.
  depends_on = [aws_lambda_invocation.bootstrap_bd]

  tags = { Name = "${var.project}-usuarios" }
}

resource "aws_apigatewayv2_integration" "usuarios" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.usuarios.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_usuarios" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /usuarios"
  target             = "integrations/${aws_apigatewayv2_integration.usuarios.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "post_usuarios" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /usuarios"
  target             = "integrations/${aws_apigatewayv2_integration.usuarios.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "apigw_usuarios" {
  statement_id  = "AllowAPIGatewayInvokeUsuarios"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.usuarios.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

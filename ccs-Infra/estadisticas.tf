# =============================================================================
# PORTAL · Endpoint ESTADÍSTICAS — GET /estadisticas/{camionId}
# -----------------------------------------------------------------------------
# Archivo autocontenido: agrega la Lambda + su ruta reutilizando el API Gateway
# y el autorizador Cognito ya definidos en api.tf. Solo agregas este archivo.
# Lee la tabla ccs-telemetria; fuera de la VPC.
# =============================================================================

resource "aws_iam_role" "estadisticas" {
  name               = "${var.project}-lambda-estadisticas"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-estadisticas" }
}

resource "aws_iam_role_policy_attachment" "estadisticas_basic" {
  role       = aws_iam_role.estadisticas.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "estadisticas" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:Query"]
    resources = [aws_dynamodb_table.telemetria.arn]
  }
}

resource "aws_iam_role_policy" "estadisticas" {
  name   = "${var.project}-estadisticas"
  role   = aws_iam_role.estadisticas.id
  policy = data.aws_iam_policy_document.estadisticas.json
}

resource "aws_lambda_function" "estadisticas" {
  function_name = "${var.project}-estadisticas"
  role          = aws_iam_role.estadisticas.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/estadisticas/estadisticas.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/estadisticas/estadisticas.zip")

  memory_size = 128
  timeout     = 15

  environment {
    variables = {
      TABLA_TELEMETRIA = aws_dynamodb_table.telemetria.name
    }
  }

  tags = { Name = "${var.project}-estadisticas" }
}

resource "aws_apigatewayv2_integration" "estadisticas" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.estadisticas.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_estadisticas" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /estadisticas/{camionId}"
  target             = "integrations/${aws_apigatewayv2_integration.estadisticas.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "apigw_estadisticas" {
  statement_id  = "AllowAPIGatewayInvokeEstadisticas"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.estadisticas.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

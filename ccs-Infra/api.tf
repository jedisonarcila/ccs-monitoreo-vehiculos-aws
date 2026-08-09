# =============================================================================
# CAPA 5 · PORTAL — Cognito + API Gateway (HTTP API) + Lambda Config Alertas
# -----------------------------------------------------------------------------
# Flujo: Postman → (JWT de Cognito) → API Gateway (valida el token) → Lambda.
#
# NOTA: este archivo es AUTOCONTENIDO a propósito (trae sus propias variables y
# outputs) para que solo tengas que agregar UN archivo, sin editar los demás.
# Si luego quieres, las variables/outputs pueden moverse a variables.tf/outputs.tf.
# =============================================================================

# ---- Variables propias de esta capa ----------------------------------------
variable "cognito_test_username" {
  description = "Usuario de prueba en Cognito (formato email)."
  type        = string
  default     = "tester@ccs.local"
}

variable "cognito_test_password" {
  description = "Contraseña del usuario de prueba. En producción sería un secreto."
  type        = string
  default     = "CcsTest2026!"
  sensitive   = true
}

# =============================================================================
# Cognito — User Pool (directorio de usuarios), client, grupos y usuario de prueba
# =============================================================================
resource "aws_cognito_user_pool" "main" {
  name                     = "${var.project}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  tags = { Name = "${var.project}-users" }
}

# App client SIN secreto (para probar con Postman/CLI) + flujo usuario/contraseña.
resource "aws_cognito_user_pool_client" "main" {
  name            = "${var.project}-client"
  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

# Los 4 roles del enunciado (sin acentos para evitar problemas de nombre).
resource "aws_cognito_user_group" "roles" {
  for_each     = toset(["Administracion", "Visualizacion", "Compra", "Aprobacion"])
  name         = each.value
  user_pool_id = aws_cognito_user_pool.main.id
}

# Usuario de prueba con contraseña permanente (queda CONFIRMED, listo para login).
resource "aws_cognito_user" "tester" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.cognito_test_username
  password     = var.cognito_test_password

  attributes = {
    email          = var.cognito_test_username
    email_verified = "true"
  }
}

resource "aws_cognito_user_in_group" "tester_admin" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.roles["Administracion"].name
  username     = aws_cognito_user.tester.username
}

# =============================================================================
# Lambda Config Alertas (fuera de la VPC: solo DynamoDB)
# =============================================================================
# Reutiliza el rol de confianza lambda_assume definido en compute.tf.
resource "aws_iam_role" "config_alertas" {
  name               = "${var.project}-lambda-config-alertas"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-lambda-config-alertas" }
}

resource "aws_iam_role_policy_attachment" "config_alertas_basic" {
  role       = aws_iam_role.config_alertas.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "config_alertas" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.config_alertas.arn]
  }
}

resource "aws_iam_role_policy" "config_alertas" {
  name   = "${var.project}-config-alertas"
  role   = aws_iam_role.config_alertas.id
  policy = data.aws_iam_policy_document.config_alertas.json
}

resource "aws_lambda_function" "config_alertas" {
  function_name = "${var.project}-config-alertas"
  role          = aws_iam_role.config_alertas.arn

  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = "${path.module}/../ccs-lambdas/config-alertas/config-alertas.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/config-alertas/config-alertas.zip")

  memory_size = 128
  timeout     = 10

  environment {
    variables = {
      TABLA_CONFIG = aws_dynamodb_table.config_alertas.name
    }
  }

  tags = { Name = "${var.project}-config-alertas" }
}

# =============================================================================
# API Gateway — HTTP API con autorizador JWT de Cognito
# =============================================================================
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  name             = "${var.project}-cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_apigatewayv2_integration" "config_alertas" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.config_alertas.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_config" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /config/{clienteId}"
  target             = "integrations/${aws_apigatewayv2_integration.config_alertas.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "put_config" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "PUT /config/{clienteId}"
  target             = "integrations/${aws_apigatewayv2_integration.config_alertas.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_config" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.config_alertas.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# =============================================================================
# Outputs de esta capa (los necesitas para probar con Postman)
# =============================================================================
output "api_endpoint" {
  description = "URL base de la API (a esta le concatenas /config/<clienteId>)."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "cognito_user_pool_id" {
  description = "ID del User Pool."
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "ID del App Client (para initiate-auth)."
  value       = aws_cognito_user_pool_client.main.id
}

output "cognito_test_username" {
  description = "Usuario de prueba para obtener el token."
  value       = var.cognito_test_username
}

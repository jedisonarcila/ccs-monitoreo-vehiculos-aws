# =============================================================================
# VENTAS · Digitalización con Step Functions (orquestación + firma del Manager)
# -----------------------------------------------------------------------------
# Flujo (máquina de estados):
#   RegistrarVenta (DynamoDB) → ¿>50 vehículos?
#      · Sí → EsperarFirmaManager (Lambda .waitForTaskToken → PAUSA) → CompletarVenta
#      · No → CompletarVenta
#
# POST /ventas                  arranca la ejecución.
# POST /ventas/{ventaId}/aprobar  reanuda la ejecución pausada (firma del Manager).
#
# Archivo autocontenido. Reutiliza api.main y authorizer.cognito de api.tf.
# =============================================================================

# ---- Tabla de ventas --------------------------------------------------------
resource "aws_dynamodb_table" "ventas" {
  name         = "${var.project}-ventas"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ventaId"

  attribute {
    name = "ventaId"
    type = "S"
  }

  tags = { Name = "${var.project}-ventas" }
}

# =============================================================================
# Lambda VENTAS-FIRMA  (tarea waitForTaskToken: guarda el token)
# =============================================================================
resource "aws_iam_role" "ventas_firma" {
  name               = "${var.project}-lambda-ventas-firma"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "ventas_firma_basic" {
  role       = aws_iam_role.ventas_firma.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "ventas_firma" {
  name = "${var.project}-ventas-firma"
  role = aws_iam_role.ventas_firma.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.ventas.arn
    }]
  })
}
resource "aws_lambda_function" "ventas_firma" {
  function_name    = "${var.project}-ventas-firma"
  role             = aws_iam_role.ventas_firma.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = "${path.module}/../ccs-lambdas/ventas-firma/ventas-firma.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/ventas-firma/ventas-firma.zip")
  memory_size      = 128
  timeout          = 15
  environment {
    variables = { TABLA_VENTAS = aws_dynamodb_table.ventas.name }
  }
  tags = { Name = "${var.project}-ventas-firma" }
}

# =============================================================================
# Máquina de estados (Step Functions)
# =============================================================================
resource "aws_iam_role" "sfn_ventas" {
  name = "${var.project}-sfn-ventas"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy" "sfn_ventas" {
  name = "${var.project}-sfn-ventas"
  role = aws_iam_role.sfn_ventas.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.ventas.arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.ventas_firma.arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "ventas" {
  name     = "${var.project}-ventas"
  role_arn = aws_iam_role.sfn_ventas.arn

  definition = jsonencode({
    Comment = "Flujo de digitalización de ventas de CCS"
    StartAt = "RegistrarVenta"
    States = {
      RegistrarVenta = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.ventas.name
          Item = {
            "ventaId"           = { "S.$" = "$.ventaId" }
            "cliente"           = { "S.$" = "$.cliente" }
            "cantidadVehiculos" = { "N.$" = "States.Format('{}', $.cantidadVehiculos)" }
            "estado"            = { "S" = "registrada" }
          }
        }
        ResultPath = null
        Next       = "RequiereFirma"
      }
      RequiereFirma = {
        Type = "Choice"
        Choices = [{
          Variable           = "$.cantidadVehiculos"
          NumericGreaterThan = 50
          Next               = "EsperarFirmaManager"
        }]
        Default = "CompletarVenta"
      }
      EsperarFirmaManager = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.ventas_firma.arn
          Payload = {
            "ventaId.$"   = "$.ventaId"
            "taskToken.$" = "$$.Task.Token"
          }
        }
        ResultPath = null
        Next       = "CompletarVenta"
      }
      CompletarVenta = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.ventas.name
          Key                       = { "ventaId" = { "S.$" = "$.ventaId" } }
          UpdateExpression          = "SET estado = :e"
          ExpressionAttributeValues = { ":e" = { "S" = "completada" } }
        }
        End = true
      }
    }
  })

  tags = { Name = "${var.project}-ventas" }
}

# =============================================================================
# Lambda VENTAS-CREAR  (POST /ventas → StartExecution)
# =============================================================================
resource "aws_iam_role" "ventas_crear" {
  name               = "${var.project}-lambda-ventas-crear"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "ventas_crear_basic" {
  role       = aws_iam_role.ventas_crear.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "ventas_crear" {
  name = "${var.project}-ventas-crear"
  role = aws_iam_role.ventas_crear.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.ventas.arn
    }]
  })
}
resource "aws_lambda_function" "ventas_crear" {
  function_name    = "${var.project}-ventas-crear"
  role             = aws_iam_role.ventas_crear.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = "${path.module}/../ccs-lambdas/ventas-crear/ventas-crear.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/ventas-crear/ventas-crear.zip")
  memory_size      = 128
  timeout          = 15
  environment {
    variables = { STATE_MACHINE_ARN = aws_sfn_state_machine.ventas.arn }
  }
  tags = { Name = "${var.project}-ventas-crear" }
}

# =============================================================================
# Lambda VENTAS-APROBAR  (POST /ventas/{ventaId}/aprobar → SendTaskSuccess)
# =============================================================================
resource "aws_iam_role" "ventas_aprobar" {
  name               = "${var.project}-lambda-ventas-aprobar"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "ventas_aprobar_basic" {
  role       = aws_iam_role.ventas_aprobar.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "ventas_aprobar" {
  name = "${var.project}-ventas-aprobar"
  role = aws_iam_role.ventas_aprobar.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.ventas.arn
      },
      {
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess"]
        Resource = "*"
      }
    ]
  })
}
resource "aws_lambda_function" "ventas_aprobar" {
  function_name    = "${var.project}-ventas-aprobar"
  role             = aws_iam_role.ventas_aprobar.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = "${path.module}/../ccs-lambdas/ventas-aprobar/ventas-aprobar.zip"
  source_code_hash = filebase64sha256("${path.module}/../ccs-lambdas/ventas-aprobar/ventas-aprobar.zip")
  memory_size      = 128
  timeout          = 15
  environment {
    variables = { TABLA_VENTAS = aws_dynamodb_table.ventas.name }
  }
  tags = { Name = "${var.project}-ventas-aprobar" }
}

# =============================================================================
# Rutas de la API (protegidas con JWT)
# =============================================================================
resource "aws_apigatewayv2_integration" "ventas_crear" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ventas_crear.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "post_ventas" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /ventas"
  target             = "integrations/${aws_apigatewayv2_integration.ventas_crear.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}
resource "aws_lambda_permission" "apigw_ventas_crear" {
  statement_id  = "AllowAPIGatewayVentasCrear"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ventas_crear.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "ventas_aprobar" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ventas_aprobar.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "post_ventas_aprobar" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /ventas/{ventaId}/aprobar"
  target             = "integrations/${aws_apigatewayv2_integration.ventas_aprobar.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}
resource "aws_lambda_permission" "apigw_ventas_aprobar" {
  statement_id  = "AllowAPIGatewayVentasAprobar"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ventas_aprobar.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

output "ventas_state_machine_arn" {
  description = "ARN de la máquina de estados de ventas."
  value       = aws_sfn_state_machine.ventas.arn
}

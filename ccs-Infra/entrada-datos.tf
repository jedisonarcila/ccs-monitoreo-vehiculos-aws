# =============================================================================
# CAPA 3 · INGESTA — Kinesis Data Streams, Kinesis Video Streams, IoT Core
# -----------------------------------------------------------------------------
# Flujo de los camiones (IoT Core Rules Engine bifurca):
#   ccs/<camionId>/telemetria  → regla → Kinesis Data Stream → (Lambda cap.4)
#   ccs/<camionId>/emergencia  → regla → Lambda Emergencia   (se crea en cap.4)
#   cámaras                    → Kinesis Video Stream        → (S3, cap.4/6)
#
# NOTA: la regla de EMERGENCIA (→ Lambda) y el cableado de SNS van en la capa 4
# (compute.tf), porque dependen de la Lambda de Emergencia. Aquí queda todo lo
# que NO depende de las Lambdas, para poder aplicarse por sí solo.
# =============================================================================

# -----------------------------------------------------------------------------
# Kinesis Data Stream · telemetría (6 shards provisionados)
# -----------------------------------------------------------------------------
resource "aws_kinesis_stream" "telemetria" {
  name             = "${var.project}-telemetria"
  shard_count      = var.kinesis_shard_count
  retention_period = var.kinesis_retention_hours

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis" # clave gestionada por AWS (sin costo extra de KMS)

  tags = { Name = "${var.project}-telemetria" }
}

# -----------------------------------------------------------------------------
# Kinesis Video Stream · grabaciones de cámaras
# -----------------------------------------------------------------------------
resource "aws_kinesis_video_stream" "camaras" {
  name                    = "${var.project}-camaras"
  data_retention_in_hours = var.kinesis_retention_hours
  media_type              = "video/h264"

  tags = { Name = "${var.project}-camaras" }
}

# -----------------------------------------------------------------------------
# Rol que asume IoT Core para escribir en Kinesis (regla de telemetría)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "iot_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iot_to_kinesis" {
  name               = "${var.project}-iot-to-kinesis"
  assume_role_policy = data.aws_iam_policy_document.iot_assume.json
  tags               = { Name = "${var.project}-iot-to-kinesis" }
}

data "aws_iam_policy_document" "iot_to_kinesis" {
  statement {
    effect    = "Allow"
    actions   = ["kinesis:PutRecord", "kinesis:PutRecords"]
    resources = [aws_kinesis_stream.telemetria.arn]
  }
}

resource "aws_iam_role_policy" "iot_to_kinesis" {
  name   = "${var.project}-iot-to-kinesis"
  role   = aws_iam_role.iot_to_kinesis.id
  policy = data.aws_iam_policy_document.iot_to_kinesis.json
}

# -----------------------------------------------------------------------------
# Regla IoT · TELEMETRÍA → Kinesis
# El publicador MQTT manda a  ccs/<camionId>/telemetria  con el JSON del punto.
# topic(2) extrae el <camionId> del topic y se usa como partition key.
# -----------------------------------------------------------------------------
resource "aws_iot_topic_rule" "telemetria" {
  name        = "${var.project}_telemetria"
  description = "Enruta la telemetría de los camiones a Kinesis Data Streams."
  enabled     = true
  sql         = "SELECT *, topic(2) AS camionId FROM '${var.iot_topic_prefix}/+/telemetria'"
  sql_version = "2016-03-23"

  kinesis {
    role_arn      = aws_iam_role.iot_to_kinesis.arn
    stream_name   = aws_kinesis_stream.telemetria.name
    partition_key = "$${topic(2)}"
  }

  tags = { Name = "${var.project}-rule-telemetria" }
}

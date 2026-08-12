# =============================================================================
# Variables de entrada
# =============================================================================

variable "region" {
  description = "Región AWS donde se despliega toda la infraestructura."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefijo de nombres y tag Project."
  type        = string
  default     = "ccs"
}

variable "environment" {
  description = "Entorno lógico (tag Environment)."
  type        = string
  default     = "reto"
}

# -----------------------------------------------------------------------------
# Zonas de disponibilidad (según diseño: us-east-1a y us-east-1b)
# -----------------------------------------------------------------------------
variable "az_a" {
  description = "Primera zona de disponibilidad."
  type        = string
  default     = "us-east-1a"
}

variable "az_b" {
  description = "Segunda zona de disponibilidad."
  type        = string
  default     = "us-east-1b"
}

# -----------------------------------------------------------------------------
# Red / VPC (CIDRs fijados en el diseño)
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR de la VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_public_a_cidr" {
  description = "Subred pública en la zona A (solo NAT)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_private_a_cidr" {
  description = "Subred privada en la zona A (Lambdas, DAX nodo 1, RDS)."
  type        = string
  default     = "10.0.2.0/24"
}

variable "subnet_public_b_cidr" {
  description = "Subred pública en la zona B (solo NAT)."
  type        = string
  default     = "10.0.3.0/24"
}

variable "subnet_private_b_cidr" {
  description = "Subred privada en la zona B (Lambdas, DAX nodo 2)."
  type        = string
  default     = "10.0.4.0/24"
}

# -----------------------------------------------------------------------------
# VPC Endpoints
# -----------------------------------------------------------------------------
# Los Gateway Endpoints (S3 y DynamoDB) son GRATIS y siempre se crean: quitan
# ese tráfico del NAT sin costo alguno.
#
# Los Interface Endpoints (Kinesis, CloudWatch Logs, etc.) SÍ tienen costo por
# hora + por GB. Se dejan detrás de un toggle, apagados por defecto para que el
# primer despliegue sea más simple y barato; el tráfico saldría por el NAT.
# Cuando se quiera optimizar el costo del NAT, se pone en true.
variable "enable_interface_endpoints" {
  description = "Crea los Interface VPC Endpoints (Kinesis, CloudWatch Logs). Con costo por hora."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Servicios para los que crear Interface Endpoints (sufijo tras com.amazonaws.<region>.)."
  type        = list(string)
  default     = ["kinesis-streams", "logs"]
  # Nota: Timestream se omite a propósito. Su soporte de PrivateLink usa
  # enrutamiento por celdas vía DescribeEndpoints y no es un endpoint estándar;
  # la Lambda de telemetría alcanza Timestream por el NAT. Se puede añadir aparte.
}

# -----------------------------------------------------------------------------
# RDS PostgreSQL
# -----------------------------------------------------------------------------
variable "rds_instance_class" {
  description = "Clase de instancia RDS (db.t4g.micro es elegible en capa gratuita)."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "Almacenamiento RDS en GB (20 = mínimo cubierto por la capa gratuita)."
  type        = number
  default     = 20
}

variable "rds_engine_version" {
  description = "Versión mayor de PostgreSQL."
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Nombre de la base de datos inicial."
  type        = string
  default     = "ccs"
}

variable "db_master_username" {
  description = "Usuario master de RDS (solo lo usa la Lambda de bootstrap)."
  type        = string
  default     = "ccs_admin"
}

variable "db_iam_username" {
  description = "Usuario de aplicación con auth IAM (rds_iam). Lo crea la Lambda de bootstrap en la capa 7."
  type        = string
  default     = "ccs_app_bd"
}

# -----------------------------------------------------------------------------
# DynamoDB
# -----------------------------------------------------------------------------
variable "dynamodb_table_name" {
  description = "Tabla de configuración de alertas."
  type        = string
  default     = "ccs-config-alertas"
}

# -----------------------------------------------------------------------------
# DAX
# -----------------------------------------------------------------------------
variable "dax_node_type" {
  description = "Tipo de nodo DAX."
  type        = string
  default     = "dax.t3.small"
}

variable "dax_replication_factor" {
  description = "Número de nodos DAX (2 = uno por zona)."
  type        = number
  default     = 2
}

# -----------------------------------------------------------------------------
# Timestream
# -----------------------------------------------------------------------------
variable "timestream_db_name" {
  description = "Base de datos Timestream."
  type        = string
  default     = "ccs"
}

variable "timestream_table_name" {
  description = "Tabla de telemetría."
  type        = string
  default     = "telemetria"
}

variable "timestream_memory_retention_hours" {
  description = "Retención en memoria (consultas recientes rápidas)."
  type        = number
  default     = 24
}

variable "timestream_magnetic_retention_days" {
  description = "Retención en almacenamiento magnético (histórico)."
  type        = number
  default     = 365
}

# -----------------------------------------------------------------------------
# Ingesta (Kinesis / IoT)
# -----------------------------------------------------------------------------
variable "kinesis_shard_count" {
  description = "Shards del stream de telemetría (6 cubren el pico de 5.000 señales/seg)."
  type        = number
  default     = 6
}

variable "kinesis_retention_hours" {
  description = "Retención de datos en el stream de Kinesis (horas)."
  type        = number
  default     = 24
}

variable "iot_topic_prefix" {
  description = "Prefijo de los topics MQTT de los camiones."
  type        = string
  default     = "ccs"
}

# -----------------------------------------------------------------------------
# Cómputo / notificaciones
# -----------------------------------------------------------------------------
variable "telemetria_table_name" {
  description = "Tabla DynamoDB de telemetría (reemplaza a Timestream)."
  type        = string
  default     = "ccs-telemetria"
}

variable "email_emergencias" {
  description = "Correo suscrito al topic SNS de emergencias para las pruebas (hay que confirmar la suscripción desde el email)."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.email_emergencias))
    error_message = "email_emergencias debe ser un correo válido, p.ej. alertas@ccs.com. No lo dejes vacío."
  }
}

variable "kinesis_batch_size" {
  description = "Registros por lote que la Lambda Telemetría procesa de Kinesis."
  type        = number
  default     = 100
}
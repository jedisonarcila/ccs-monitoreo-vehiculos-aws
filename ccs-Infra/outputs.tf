# =============================================================================
# Outputs de la fundación/red (los consumen las capas siguientes)
# =============================================================================

output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Subredes privadas (Lambdas en VPC, DAX, RDS)."
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "public_subnet_ids" {
  description = "Subredes públicas (solo NAT)."
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "sg_lambdas_id" {
  description = "SG de las Lambdas en VPC."
  value       = aws_security_group.lambdas.id
}

output "sg_rds_id" {
  description = "SG de RDS."
  value       = aws_security_group.rds.id
}

output "sg_dax_id" {
  description = "SG de DAX."
  value       = aws_security_group.dax.id
}

output "nat_gateway_ids" {
  description = "NAT Gateways (uno por zona)."
  value       = [aws_nat_gateway.a.id, aws_nat_gateway.b.id]
}

# =============================================================================
# Outputs de la capa de datos
# =============================================================================

output "rds_endpoint" {
  description = "Host de la RDS PostgreSQL (para RDS_HOST de las Lambdas)."
  value       = aws_db_instance.main.address
}

output "dynamodb_table" {
  description = "Nombre de la tabla de config de alertas."
  value       = aws_dynamodb_table.config_alertas.name
}

output "dax_endpoint" {
  description = "Endpoint del clúster DAX (DAX_ENDPOINT de la Lambda Emergencia)."
  value       = aws_dax_cluster.main.cluster_address
}

/*
output "timestream_database" {
  description = "Base de datos Timestream."
  value       = aws_timestreamwrite_database.main.database_name
}
*/

output "s3_buckets" {
  description = "Nombres reales de los tres buckets (con sufijo aleatorio)."
  value = {
    static  = aws_s3_bucket.static.bucket
    video   = aws_s3_bucket.video.bucket
    backups = aws_s3_bucket.backups.bucket
  }
}

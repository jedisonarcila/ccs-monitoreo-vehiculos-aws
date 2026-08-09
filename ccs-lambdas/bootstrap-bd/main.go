// Lambda BOOTSTRAP BD
// -----------------------------------------------------------------------------
// La invoca Terraform (aws_lambda_invocation) durante el apply. Se conecta a
// Postgres con la credencial MAESTRA y deja el esquema listo, de forma
// IDEMPOTENTE (se puede re-ejecutar sin romper nada):
//   - crea el rol de aplicación con GRANT rds_iam (autenticación IAM, sin claves)
//   - crea las tablas usuarios y facturas
//   - otorga permisos al rol de aplicación
//
// Corre DENTRO de la VPC (subred privada) para alcanzar RDS. Se deja desplegada.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/jackc/pgx/v5"
)

func handler(ctx context.Context) (string, error) {
	host := os.Getenv("DB_HOST")
	port := os.Getenv("DB_PORT")
	dbname := os.Getenv("DB_NAME")
	master := os.Getenv("DB_MASTER_USER")
	masterPass := os.Getenv("DB_MASTER_PASSWORD")
	appUser := os.Getenv("DB_APP_USER")

	// La contraseña NO va en el connString (evita problemas de escape): se pone aparte.
	cfg, err := pgx.ParseConfig(fmt.Sprintf("host=%s port=%s dbname=%s", host, port, dbname))
	if err != nil {
		return "", fmt.Errorf("config: %w", err)
	}
	cfg.User = master
	cfg.Password = masterPass
	cfg.TLSConfig = &tls.Config{InsecureSkipVerify: true} // RDS exige SSL; en prod usar el CA bundle de RDS

	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return "", fmt.Errorf("conexión maestra a Postgres: %w", err)
	}
	defer conn.Close(ctx)

	// %[1]s repite el mismo valor (appUser) en todas las posiciones.
	sql := fmt.Sprintf(`
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%[1]s') THEN
    CREATE USER %[1]s;
  END IF;
END
$$;
GRANT rds_iam TO %[1]s;

CREATE TABLE IF NOT EXISTS usuarios (
  id        SERIAL PRIMARY KEY,
  nombre    TEXT NOT NULL,
  email     TEXT UNIQUE NOT NULL,
  rol       TEXT NOT NULL,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS facturas (
  id         SERIAL PRIMARY KEY,
  cliente_id TEXT NOT NULL,
  monto      NUMERIC(12,2) NOT NULL,
  concepto   TEXT NOT NULL,
  estado     TEXT NOT NULL DEFAULT 'pendiente',
  creado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON usuarios TO %[1]s;
GRANT SELECT, INSERT, UPDATE, DELETE ON facturas TO %[1]s;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %[1]s;
`, appUser)

	if _, err := conn.Exec(ctx, sql); err != nil {
		return "", fmt.Errorf("ejecutando SQL de bootstrap: %w", err)
	}

	return fmt.Sprintf("bootstrap OK: rol '%s' con rds_iam + tablas usuarios/facturas listas", appUser), nil
}

func main() {
	lambda.Start(handler)
}
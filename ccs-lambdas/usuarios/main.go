// Lambda USUARIOS  (endpoint del portal, usa RDS PostgreSQL)
// -----------------------------------------------------------------------------
//   GET  /usuarios   -> lista los usuarios
//   POST /usuarios   -> crea un usuario {nombre, email, rol}
//
// Se conecta a Postgres con AUTENTICACIÓN IAM: en lugar de una contraseña, genera
// un token temporal firmado (rds-db:connect). Cero contraseñas guardadas.
// Corre DENTRO de la VPC (subred privada) para alcanzar RDS.
package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/jackc/pgx/v5"
)

type Usuario struct {
	ID       int    `json:"id"`
	Nombre   string `json:"nombre"`
	Email    string `json:"email"`
	Rol      string `json:"rol"`
	CreadoEn string `json:"creadoEn,omitempty"`
}

var host, port, dbname, dbUser, region string

func init() {
	host = os.Getenv("DB_HOST")
	port = os.Getenv("DB_PORT")
	dbname = os.Getenv("DB_NAME")
	dbUser = os.Getenv("DB_APP_USER")
	region = os.Getenv("AWS_REGION") // lo inyecta el runtime de Lambda
}

// conectar genera un token IAM y abre la conexión a Postgres.
func conectar(ctx context.Context) (*pgx.Conn, error) {
	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}
	endpoint := fmt.Sprintf("%s:%s", host, port)
	token, err := auth.BuildAuthToken(ctx, endpoint, region, dbUser, awsCfg.Credentials)
	if err != nil {
		return nil, fmt.Errorf("generando token IAM: %w", err)
	}

	cfg, err := pgx.ParseConfig(fmt.Sprintf("host=%s port=%s dbname=%s", host, port, dbname))
	if err != nil {
		return nil, err
	}
	cfg.User = dbUser
	cfg.Password = token
	cfg.TLSConfig = &tls.Config{InsecureSkipVerify: true} // RDS exige SSL

	return pgx.ConnectConfig(ctx, cfg)
}

func resp(code int, body any) (events.APIGatewayV2HTTPResponse, error) {
	b, _ := json.Marshal(body)
	return events.APIGatewayV2HTTPResponse{
		StatusCode: code,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(b),
	}, nil
}

func handler(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	conn, err := conectar(ctx)
	if err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": "conexión BD: " + err.Error()})
	}
	defer conn.Close(ctx)

	switch req.RequestContext.HTTP.Method {

	case http.MethodGet:
		rows, err := conn.Query(ctx, "SELECT id, nombre, email, rol, creado_en FROM usuarios ORDER BY id")
		if err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		defer rows.Close()

		usuarios := []Usuario{}
		for rows.Next() {
			var u Usuario
			var creado time.Time
			if err := rows.Scan(&u.ID, &u.Nombre, &u.Email, &u.Rol, &creado); err != nil {
				return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
			}
			u.CreadoEn = creado.Format(time.RFC3339)
			usuarios = append(usuarios, u)
		}
		return resp(http.StatusOK, usuarios)

	case http.MethodPost:
		body := req.Body
		if req.IsBase64Encoded {
			if dec, err := base64.StdEncoding.DecodeString(body); err == nil {
				body = string(dec)
			}
		}
		var u Usuario
		if err := json.Unmarshal([]byte(body), &u); err != nil {
			return resp(http.StatusBadRequest, map[string]string{"error": "JSON inválido"})
		}
		if u.Nombre == "" || u.Email == "" || u.Rol == "" {
			return resp(http.StatusBadRequest, map[string]string{"error": "nombre, email y rol son obligatorios"})
		}
		err := conn.QueryRow(ctx,
			"INSERT INTO usuarios (nombre, email, rol) VALUES ($1, $2, $3) RETURNING id",
			u.Nombre, u.Email, u.Rol,
		).Scan(&u.ID)
		if err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		return resp(http.StatusCreated, u)

	default:
		return resp(http.StatusMethodNotAllowed, map[string]string{"error": "método no soportado"})
	}
}

func main() {
	log.SetFlags(0)
	lambda.Start(handler)
}

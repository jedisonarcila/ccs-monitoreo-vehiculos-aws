// Lambda FINANCIERO  (endpoint del portal, usa RDS PostgreSQL)
// -----------------------------------------------------------------------------
//   GET  /facturas   -> lista las facturas
//   POST /facturas   -> crea una factura {clienteId, monto, concepto}
//
// Mismo patrón que Usuarios: se conecta a Postgres con AUTENTICACIÓN IAM (token
// temporal, sin contraseña). Corre DENTRO de la VPC. En producción, el pago se
// resolvería contra una pasarela (Wompi/PayU); aquí se registra el estado.
package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/jackc/pgx/v5"
)

type Factura struct {
	ID        int     `json:"id"`
	ClienteID string  `json:"clienteId"`
	Monto     float64 `json:"monto"`
	Concepto  string  `json:"concepto"`
	Estado    string  `json:"estado"`
	CreadoEn  string  `json:"creadoEn,omitempty"`
}

var host, port, dbname, dbUser, region string

func init() {
	host = os.Getenv("DB_HOST")
	port = os.Getenv("DB_PORT")
	dbname = os.Getenv("DB_NAME")
	dbUser = os.Getenv("DB_APP_USER")
	region = os.Getenv("AWS_REGION")
}

func conectar(ctx context.Context) (*pgx.Conn, error) {
	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}
	endpoint := fmt.Sprintf("%s:%s", host, port)
	token, err := auth.BuildAuthToken(ctx, endpoint, region, dbUser, awsCfg.Credentials)
	if err != nil {
		return nil, fmt.Errorf("token IAM: %w", err)
	}
	cfg, err := pgx.ParseConfig(fmt.Sprintf("host=%s port=%s dbname=%s", host, port, dbname))
	if err != nil {
		return nil, err
	}
	cfg.User = dbUser
	cfg.Password = token
	cfg.TLSConfig = &tls.Config{InsecureSkipVerify: true}
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
		rows, err := conn.Query(ctx, "SELECT id, cliente_id, monto, concepto, estado, creado_en FROM facturas ORDER BY id")
		if err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		defer rows.Close()

		facturas := []Factura{}
		for rows.Next() {
			var f Factura
			var creado time.Time
			if err := rows.Scan(&f.ID, &f.ClienteID, &f.Monto, &f.Concepto, &f.Estado, &creado); err != nil {
				return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
			}
			f.CreadoEn = creado.Format(time.RFC3339)
			facturas = append(facturas, f)
		}
		return resp(http.StatusOK, facturas)

	case http.MethodPost:
		body := req.Body
		if req.IsBase64Encoded {
			if dec, err := base64.StdEncoding.DecodeString(body); err == nil {
				body = string(dec)
			}
		}
		var f Factura
		if err := json.Unmarshal([]byte(body), &f); err != nil {
			return resp(http.StatusBadRequest, map[string]string{"error": "JSON inválido"})
		}
		if f.ClienteID == "" || f.Monto <= 0 || f.Concepto == "" {
			return resp(http.StatusBadRequest, map[string]string{"error": "clienteId, monto (>0) y concepto son obligatorios"})
		}
		// Estado inicial: pendiente de pago (en producción lo actualizaría la pasarela Wompi/PayU).
		err := conn.QueryRow(ctx,
			"INSERT INTO facturas (cliente_id, monto, concepto, estado) VALUES ($1, $2, $3, 'pendiente') RETURNING id, estado",
			f.ClienteID, f.Monto, f.Concepto,
		).Scan(&f.ID, &f.Estado)
		if err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		return resp(http.StatusCreated, f)

	default:
		return resp(http.StatusMethodNotAllowed, map[string]string{"error": "método no soportado"})
	}
}

func main() {
	lambda.Start(handler)
}

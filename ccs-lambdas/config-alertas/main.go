// Lambda CONFIG ALERTAS  (endpoint del portal, detrás de API Gateway + Cognito)
// -----------------------------------------------------------------------------
// Atiende dos rutas sobre la tabla ccs-config-alertas:
//   GET  /config/{clienteId}  -> devuelve la configuración de alertas del cliente
//   PUT  /config/{clienteId}  -> crea/actualiza la configuración del cliente
//
// Integración HTTP API (payload v2.0): recibe APIGatewayV2HTTPRequest y responde
// APIGatewayV2HTTPResponse. NO va en la VPC (solo toca DynamoDB).
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// ConfigAlertas: qué alertas quiere el cliente y por dónde recibirlas.
type ConfigAlertas struct {
	ClienteID          string   `json:"clienteId"                    dynamodbav:"clienteId"`
	Email              string   `json:"email,omitempty"              dynamodbav:"email,omitempty"`
	Telefono           string   `json:"telefono,omitempty"           dynamodbav:"telefono,omitempty"`
	AlertasHabilitadas []string `json:"alertasHabilitadas,omitempty" dynamodbav:"alertasHabilitadas,omitempty"`
}

var (
	ddb   *dynamodb.Client
	tabla string
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		log.Fatalf("config AWS: %v", err)
	}
	ddb = dynamodb.NewFromConfig(cfg)
	tabla = os.Getenv("TABLA_CONFIG")
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
	clienteID := req.PathParameters["clienteId"]
	metodo := req.RequestContext.HTTP.Method
	log.Printf("%s /config/%s", metodo, clienteID)

	if clienteID == "" {
		return resp(http.StatusBadRequest, map[string]string{"error": "falta clienteId"})
	}

	switch metodo {

	case http.MethodGet:
		out, err := ddb.GetItem(ctx, &dynamodb.GetItemInput{
			TableName: aws.String(tabla),
			Key: map[string]ddbtypes.AttributeValue{
				"clienteId": &ddbtypes.AttributeValueMemberS{Value: clienteID},
			},
		})
		if err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		if out.Item == nil {
			return resp(http.StatusNotFound, map[string]string{"mensaje": "sin configuracion para " + clienteID})
		}
		var cfg ConfigAlertas
		if err := attributevalue.UnmarshalMap(out.Item, &cfg); err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		return resp(http.StatusOK, cfg)

	case http.MethodPut:
		body := req.Body
		if req.IsBase64Encoded {
			if dec, err := base64.StdEncoding.DecodeString(body); err == nil {
				body = string(dec)
			}
		}
		var cfg ConfigAlertas
		if err := json.Unmarshal([]byte(body), &cfg); err != nil {
			return resp(http.StatusBadRequest, map[string]string{"error": "JSON invalido"})
		}
		cfg.ClienteID = clienteID // la ruta manda sobre el body

		item, err := attributevalue.MarshalMap(cfg)
		if err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		if _, err := ddb.PutItem(ctx, &dynamodb.PutItemInput{
			TableName: aws.String(tabla),
			Item:      item,
		}); err != nil {
			return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		return resp(http.StatusOK, map[string]string{"mensaje": "configuracion guardada", "clienteId": clienteID})

	default:
		return resp(http.StatusMethodNotAllowed, map[string]string{"error": "metodo no soportado"})
	}
}

func main() {
	lambda.Start(handler)
}

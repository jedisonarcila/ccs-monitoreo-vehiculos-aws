// Lambda EMERGENCIA
// -----------------------------------------------------------------------------
// La dispara la regla IoT cuando un camión publica en ccs/<camionId>/emergencia.
// 1) Deserializa la señal de emergencia.
// 2) Lee la configuración de alertas del cliente en DynamoDB (patrón de lectura;
//    en la arquitectura este acceso pasa por DAX para latencia de microsegundos —
//    ver nota abajo sobre cómo conmutar a DAX).
// 3) Publica la notificación en el topic SNS de emergencias (llega por email).
//
// Campos del JSON de emergencia (en español, esquema acordado):
//   { "clienteId", "camionId", "latitud", "longitud", "tipo", "timestamp" }
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/aws/aws-sdk-go-v2/service/sns"
)

// Emergencia es el esquema de la señal que publica el camión.
type Emergencia struct {
	ClienteID string  `json:"clienteId"`
	CamionID  string  `json:"camionId"`
	Latitud   float64 `json:"latitud"`
	Longitud  float64 `json:"longitud"`
	Tipo      string  `json:"tipo"`
	Timestamp int64   `json:"timestamp"`
}

var (
	ddb         *dynamodb.Client
	snsCli      *sns.Client
	tablaConfig string
	topicArn    string
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		log.Fatalf("no se pudo cargar la config de AWS: %v", err)
	}
	ddb = dynamodb.NewFromConfig(cfg)
	snsCli = sns.NewFromConfig(cfg)
	tablaConfig = os.Getenv("TABLA_CONFIG")
	topicArn = os.Getenv("TOPIC_EMERGENCIAS")
}

func handler(ctx context.Context, e Emergencia) error {
	log.Printf("Emergencia recibida: cliente=%s camion=%s tipo=%s", e.ClienteID, e.CamionID, e.Tipo)

	// 2) Lectura de configuración del cliente.
	// NOTA DAX: en la arquitectura este GetItem va por DAX (microsegundos). Para
	// conmutar a DAX: usar el cliente aws-dax-go apuntando a os.Getenv("DAX_ENDPOINT")
	// en lugar de ddb; la interfaz GetItem es idéntica. Aquí se lee DynamoDB directo
	// por robustez en la primera versión.
	out, err := ddb.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(tablaConfig),
		Key: map[string]ddbtypes.AttributeValue{
			"clienteId": &ddbtypes.AttributeValueMemberS{Value: e.ClienteID},
		},
	})
	switch {
	case err != nil:
		log.Printf("aviso: no se pudo leer config del cliente %s: %v (se notifica igual)", e.ClienteID, err)
	case out.Item == nil:
		log.Printf("aviso: cliente %s sin config; se usa notificación por defecto", e.ClienteID)
	default:
		log.Printf("config del cliente %s encontrada", e.ClienteID)
	}

	// 3) Notificación vía SNS.
	asunto := fmt.Sprintf("EMERGENCIA %s - camion %s", e.Tipo, e.CamionID)
	if len(asunto) > 99 {
		asunto = asunto[:99] // límite de SNS para Subject
	}

	_, err = snsCli.Publish(ctx, &sns.PublishInput{
		TopicArn: aws.String(topicArn),
		Subject:  aws.String(asunto),
		Message:  aws.String(construirMensaje(e)),
	})
	if err != nil {
		return fmt.Errorf("error publicando en SNS: %w", err)
	}

	log.Printf("Notificacion enviada para camion %s", e.CamionID)
	return nil
}

func construirMensaje(e Emergencia) string {
	hora := time.Unix(e.Timestamp, 0).UTC().Format("2006-01-02 15:04:05 UTC")
	maps := fmt.Sprintf("https://www.google.com/maps?q=%f,%f", e.Latitud, e.Longitud)
	return fmt.Sprintf(
		"ALERTA DE EMERGENCIA\n\n"+
			"Tipo:      %s\n"+
			"Cliente:   %s\n"+
			"Camion:    %s\n"+
			"Ubicacion: %f, %f\n"+
			"Mapa:      %s\n"+
			"Hora:      %s\n",
		e.Tipo, e.ClienteID, e.CamionID, e.Latitud, e.Longitud, maps, hora,
	)
}

func main() {
	lambda.Start(handler)
}

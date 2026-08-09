// Lambda TELEMETRÍA
// -----------------------------------------------------------------------------
// La dispara Kinesis (event source mapping): el servicio Lambda lee lotes de
// registros del stream ccs-telemetria y los entrega a esta función.
// 1) Deserializa cada punto de telemetría (esquema completo del camión).
// 2) Los guarda en la tabla DynamoDB ccs-telemetria (PK camionId + SK timestamp),
//    en lotes con BatchWriteItem.
//
// NOTA DE DISEÑO: esta Lambda NO va en la VPC. Solo lee de Kinesis (vía el poller
// del servicio Lambda, con permisos IAM) y escribe en DynamoDB (endpoint público).
// No toca RDS ni DAX, así que fuera de la VPC = arranque más rápido y sin NAT.
//
// Esquema de telemetría (campos en español):
//   { clienteId, camionId, latitud, longitud, velocidad, direccion,
//     estadoCarga, temperaturaCarga, detencion, timestamp }
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// Punto es un registro de telemetría. Los tags dynamodbav definen cómo se guarda.
type Punto struct {
	CamionID         string  `json:"camionId"         dynamodbav:"camionId"`  // PK
	Timestamp        int64   `json:"timestamp"        dynamodbav:"timestamp"` // SK
	ClienteID        string  `json:"clienteId"        dynamodbav:"clienteId"`
	Latitud          float64 `json:"latitud"          dynamodbav:"latitud"`
	Longitud         float64 `json:"longitud"         dynamodbav:"longitud"`
	Velocidad        float64 `json:"velocidad"        dynamodbav:"velocidad"`
	Direccion        string  `json:"direccion"        dynamodbav:"direccion"`
	EstadoCarga      string  `json:"estadoCarga"      dynamodbav:"estadoCarga"`
	TemperaturaCarga float64 `json:"temperaturaCarga" dynamodbav:"temperaturaCarga"`
	Detencion        string  `json:"detencion"        dynamodbav:"detencion"`
}

var (
	ddb   *dynamodb.Client
	tabla string
)

func init() {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		log.Fatalf("no se pudo cargar la config de AWS: %v", err)
	}
	ddb = dynamodb.NewFromConfig(cfg)
	tabla = os.Getenv("TABLA_TELEMETRIA")
}

func handler(ctx context.Context, e events.KinesisEvent) error {
	log.Printf("Telemetria: %d registros recibidos de Kinesis", len(e.Records))

	var writes []ddbtypes.WriteRequest
	for _, r := range e.Records {
		var p Punto
		if err := json.Unmarshal(r.Kinesis.Data, &p); err != nil {
			log.Printf("registro invalido, se omite: %v", err)
			continue
		}
		item, err := attributevalue.MarshalMap(p)
		if err != nil {
			log.Printf("no se pudo serializar el punto de %s: %v", p.CamionID, err)
			continue
		}
		writes = append(writes, ddbtypes.WriteRequest{
			PutRequest: &ddbtypes.PutRequest{Item: item},
		})
	}

	// DynamoDB acepta máximo 25 escrituras por BatchWriteItem: se trocea.
	for i := 0; i < len(writes); i += 25 {
		fin := i + 25
		if fin > len(writes) {
			fin = len(writes)
		}
		out, err := ddb.BatchWriteItem(ctx, &dynamodb.BatchWriteItemInput{
			RequestItems: map[string][]ddbtypes.WriteRequest{tabla: writes[i:fin]},
		})
		if err != nil {
			return fmt.Errorf("BatchWriteItem: %w", err)
		}
		if len(out.UnprocessedItems) > 0 {
			// En producción se reintentarían con backoff; aquí se registra.
			log.Printf("aviso: %d items no procesados en este lote", len(out.UnprocessedItems[tabla]))
		}
	}

	log.Printf("Telemetria: %d puntos guardados en %s", len(writes), tabla)
	return nil
}

func main() {
	lambda.Start(handler)
}

// Lambda VENTAS-FIRMA  (tarea .waitForTaskToken de Step Functions)
// -----------------------------------------------------------------------------
// Cuando una venta supera 50 vehículos, la máquina de estados invoca esta Lambda
// pasándole el TASK TOKEN y se PAUSA. Aquí guardamos el token junto a la venta,
// para que luego el endpoint de aprobación pueda reanudar el flujo (SendTaskSuccess).
package main

import (
	"context"
	"log"
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

type Entrada struct {
	VentaID   string `json:"ventaId"`
	TaskToken string `json:"taskToken"`
}

var (
	ddb   *dynamodb.Client
	tabla string
)

func init() {
	cfg, _ := config.LoadDefaultConfig(context.TODO())
	ddb = dynamodb.NewFromConfig(cfg)
	tabla = os.Getenv("TABLA_VENTAS")
}

func handler(ctx context.Context, e Entrada) (string, error) {
	log.Printf("venta %s en espera de firma del Manager", e.VentaID)
	_, err := ddb.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(tabla),
		Key: map[string]ddbtypes.AttributeValue{
			"ventaId": &ddbtypes.AttributeValueMemberS{Value: e.VentaID},
		},
		UpdateExpression: aws.String("SET taskToken = :t, estado = :e"),
		ExpressionAttributeValues: map[string]ddbtypes.AttributeValue{
			":t": &ddbtypes.AttributeValueMemberS{Value: e.TaskToken},
			":e": &ddbtypes.AttributeValueMemberS{Value: "pendiente_firma_manager"},
		},
	})
	if err != nil {
		return "", err
	}
	// La máquina de estados NO continúa con este return: queda esperando el token.
	return "token guardado", nil
}

func main() {
	lambda.Start(handler)
}

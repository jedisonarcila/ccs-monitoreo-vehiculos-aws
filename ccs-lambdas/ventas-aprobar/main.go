// Lambda VENTAS-APROBAR  (POST /ventas/{ventaId}/aprobar)
// -----------------------------------------------------------------------------
// La "firma del Manager": lee el task token guardado para esa venta y reanuda la
// máquina de estados con SendTaskSuccess. El flujo continúa hasta completar la venta.
package main

import (
	"context"
	"net/http"
	"encoding/json"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddbtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/aws/aws-sdk-go-v2/service/sfn"
)

var (
	ddb    *dynamodb.Client
	sfnCli *sfn.Client
	tabla  string
)

func init() {
	cfg, _ := config.LoadDefaultConfig(context.TODO())
	ddb = dynamodb.NewFromConfig(cfg)
	sfnCli = sfn.NewFromConfig(cfg)
	tabla = os.Getenv("TABLA_VENTAS")
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
	ventaID := req.PathParameters["ventaId"]
	if ventaID == "" {
		return resp(http.StatusBadRequest, map[string]string{"error": "falta ventaId"})
	}

	out, err := ddb.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(tabla),
		Key: map[string]ddbtypes.AttributeValue{
			"ventaId": &ddbtypes.AttributeValueMemberS{Value: ventaID},
		},
	})
	if err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	if out.Item == nil {
		return resp(http.StatusNotFound, map[string]string{"error": "venta no encontrada"})
	}
	tok, ok := out.Item["taskToken"].(*ddbtypes.AttributeValueMemberS)
	if !ok || tok.Value == "" {
		return resp(http.StatusConflict, map[string]string{"error": "la venta no está esperando firma"})
	}

	// Reanuda la máquina de estados: la venta queda aprobada y se completa.
	_, err = sfnCli.SendTaskSuccess(ctx, &sfn.SendTaskSuccessInput{
		TaskToken: aws.String(tok.Value),
		Output:    aws.String(`{"aprobado": true, "firmadoPor": "manager"}`),
	})
	if err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	return resp(http.StatusOK, map[string]string{"ventaId": ventaID, "estado": "aprobada"})
}

func main() {
	lambda.Start(handler)
}

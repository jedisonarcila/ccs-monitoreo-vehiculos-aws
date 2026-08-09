// Lambda VENTAS-CREAR  (POST /ventas)
// -----------------------------------------------------------------------------
// Arranca una ejecución de la máquina de estados de ventas (Step Functions).
// El flujo decide solo si la venta requiere firma del Manager (>50 vehículos).
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sfn"
)

type Venta struct {
	Cliente           string `json:"cliente"`
	CantidadVehiculos int    `json:"cantidadVehiculos"`
}

var (
	sfnCli *sfn.Client
	smArn  string
)

func init() {
	cfg, _ := config.LoadDefaultConfig(context.TODO())
	sfnCli = sfn.NewFromConfig(cfg)
	smArn = os.Getenv("STATE_MACHINE_ARN")
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
	body := req.Body
	if req.IsBase64Encoded {
		if dec, err := base64.StdEncoding.DecodeString(body); err == nil {
			body = string(dec)
		}
	}
	var v Venta
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		return resp(http.StatusBadRequest, map[string]string{"error": "JSON inválido"})
	}
	if v.Cliente == "" || v.CantidadVehiculos <= 0 {
		return resp(http.StatusBadRequest, map[string]string{"error": "cliente y cantidadVehiculos (>0) son obligatorios"})
	}

	ventaID := fmt.Sprintf("V-%d", time.Now().UnixNano())
	input, _ := json.Marshal(map[string]any{
		"ventaId":           ventaID,
		"cliente":           v.Cliente,
		"cantidadVehiculos": v.CantidadVehiculos,
	})

	_, err := sfnCli.StartExecution(ctx, &sfn.StartExecutionInput{
		StateMachineArn: aws.String(smArn),
		Name:            aws.String(ventaID),
		Input:           aws.String(string(input)),
	})
	if err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	requiereFirma := v.CantidadVehiculos > 50
	estado := "en_proceso"
	if requiereFirma {
		estado = "pendiente_firma_manager"
	}
	return resp(http.StatusAccepted, map[string]any{
		"ventaId":       ventaID,
		"estado":        estado,
		"requiereFirma": requiereFirma,
	})
}

func main() {
	lambda.Start(handler)
}

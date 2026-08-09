// Lambda ESTADÍSTICAS  (endpoint del portal Plan Plus)
// -----------------------------------------------------------------------------
//   GET /estadisticas/{camionId}?desde=<epoch>&hasta=<epoch>
// Consulta los puntos de telemetría del camión en el rango y calcula:
//   - distancia recorrida (km, suma de Haversine entre puntos consecutivos)
//   - tiempo en movimiento (segundos donde hubo desplazamiento)
//   - velocidad máxima y promedio
// Fuera de la VPC (solo lee DynamoDB ccs-telemetria).
package main

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/expression"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
)

type Punto struct {
	Timestamp int64   `dynamodbav:"timestamp"`
	Latitud   float64 `dynamodbav:"latitud"`
	Longitud  float64 `dynamodbav:"longitud"`
	Velocidad float64 `dynamodbav:"velocidad"`
}

type Estadisticas struct {
	CamionID                 string  `json:"camionId"`
	Puntos                   int     `json:"puntos"`
	DistanciaKm              float64 `json:"distanciaKm"`
	TiempoMovimientoSegundos int64   `json:"tiempoMovimientoSegundos"`
	VelocidadMaxima          float64 `json:"velocidadMaxima"`
	VelocidadPromedio        float64 `json:"velocidadPromedio"`
	Desde                    int64   `json:"desde"`
	Hasta                    int64   `json:"hasta"`
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
	tabla = os.Getenv("TABLA_TELEMETRIA")
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
	camionID := req.PathParameters["camionId"]
	if camionID == "" {
		return resp(http.StatusBadRequest, map[string]string{"error": "falta camionId"})
	}
	desde := parseInt(req.QueryStringParameters["desde"], 0)
	hasta := parseInt(req.QueryStringParameters["hasta"], 9999999999999)
	log.Printf("estadisticas camion=%s desde=%d hasta=%d", camionID, desde, hasta)

	// Query por camionId (PK) y rango de timestamp (SK).
	keyCond := expression.Key("camionId").Equal(expression.Value(camionID)).
		And(expression.Key("timestamp").Between(expression.Value(desde), expression.Value(hasta)))
	expr, err := expression.NewBuilder().WithKeyCondition(keyCond).Build()
	if err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	out, err := ddb.Query(ctx, &dynamodb.QueryInput{
		TableName:                 aws.String(tabla),
		KeyConditionExpression:    expr.KeyCondition(),
		ExpressionAttributeNames:  expr.Names(),
		ExpressionAttributeValues: expr.Values(),
	})
	if err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	var puntos []Punto
	if err := attributevalue.UnmarshalListOfMaps(out.Items, &puntos); err != nil {
		return resp(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	est := calcular(camionID, puntos)
	return resp(http.StatusOK, est)
}

func calcular(camionID string, puntos []Punto) Estadisticas {
	est := Estadisticas{CamionID: camionID, Puntos: len(puntos)}
	if len(puntos) == 0 {
		return est
	}
	sort.Slice(puntos, func(i, j int) bool { return puntos[i].Timestamp < puntos[j].Timestamp })
	est.Desde = puntos[0].Timestamp
	est.Hasta = puntos[len(puntos)-1].Timestamp

	var sumVel float64
	for i, p := range puntos {
		sumVel += p.Velocidad
		if p.Velocidad > est.VelocidadMaxima {
			est.VelocidadMaxima = p.Velocidad
		}
		if i > 0 {
			est.DistanciaKm += haversineKm(puntos[i-1], p)
			// Cuenta como "en movimiento" si hubo velocidad en el tramo.
			if puntos[i-1].Velocidad > 0 || p.Velocidad > 0 {
				est.TiempoMovimientoSegundos += p.Timestamp - puntos[i-1].Timestamp
			}
		}
	}
	est.VelocidadPromedio = round2(sumVel / float64(len(puntos)))
	est.DistanciaKm = round2(est.DistanciaKm)
	return est
}

// haversineKm calcula la distancia en km entre dos coordenadas.
func haversineKm(a, b Punto) float64 {
	const R = 6371.0
	dLat := rad(b.Latitud - a.Latitud)
	dLon := rad(b.Longitud - a.Longitud)
	lat1, lat2 := rad(a.Latitud), rad(b.Latitud)
	h := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * R * math.Asin(math.Sqrt(h))
}

func rad(d float64) float64   { return d * math.Pi / 180 }
func round2(f float64) float64 { return math.Round(f*100) / 100 }

func parseInt(s string, def int64) int64 {
	if s == "" {
		return def
	}
	if v, err := strconv.ParseInt(s, 10, 64); err == nil {
		return v
	}
	return def
}

func main() {
	lambda.Start(handler)
}

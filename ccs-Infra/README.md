# CCS — Infraestructura AWS (Terraform)

Compañía Colombiana de Seguimiento de Vehículos · arquitectura serverless · región `us-east-1`.

Este proyecto aprovisiona la central de CCS: ingesta de emergencias y telemetría,
portal Plan Plus, digitalización de ventas y almacenamiento.

---

## Organización de los archivos

Los archivos se agrupan **por dominio/capa**, no uno por servicio. A Terraform le
da igual (concatena todos los `.tf` de la carpeta en un solo grafo); la división
es para las personas. Agrupar por dominio mantiene cada archivo cohesivo y evita
una maraña de archivos diminutos.

| Archivo         | Capa | Contenido |
|-----------------|------|-----------|
| `main.tf`       | 0 | provider AWS, versiones, **backend local** |
| `variables.tf`  | 0 | todas las variables de entrada con sus defaults |
| `outputs.tf`    | 0 | salidas (VPC, subredes, SGs, RDS, DAX, DynamoDB, S3...) |
| `network.tf`    | 1 | VPC, **Internet Gateway**, subredes, NAT, route tables, security groups, VPC endpoints |
| `data.tf`       | 2 | RDS PostgreSQL, DynamoDB, DAX (+ su rol IAM), Timestream |
| `storage.tf`    | 2 | 3 buckets S3 (estático, video, backups) con lifecycle y cifrado |
| `ingest.tf`     | 3 | *(pendiente)* IoT Core + reglas, Kinesis Data/Video Streams, SNS |
| `compute.tf` / `iam.tf` | 4 | *(pendiente)* las Lambdas Go + sus roles/políticas |
| `api.tf`        | 5 | *(pendiente)* Cognito, API Gateway, Step Functions |
| `edge.tf`       | 6 | *(pendiente)* CloudFront, WAF, Route 53, AWS Backup |
| bootstrap BD    | 7 | *(pendiente)* Lambda que crea el usuario IAM en Postgres |

> `compute.tf` y `api.tf` pueden partirse en dos archivos cada uno si crecen mucho.
> La regla no es dogmática: se agrupa por dominio, pero se divide un dominio
> cuando el tamaño lo pide. **Cohesión y tamaño mandan, no la etiqueta.**

El código Go de las Lambdas vive aparte, en `../ccs-lambdas/` (se compila a `.zip`
y Terraform sube esos artefactos).

---

## Decisiones de alcance (qué está y qué no)

### QuickSight — FUERA del despliegue
Los dashboards del Plan Plus **no** se aprovisionan con QuickSight en este IaC.
Dos razones:
1. QuickSight es difícil de gestionar por Terraform (la suscripción de la cuenta
   y los usuarios se aprovisionan por consola, no por API).
2. Las estadísticas del Plan Plus pueden resolverse **en el front**: la Lambda
   `Estadísticas` (Go) consulta agregados en Timestream (distancia/tiempo por
   rango) y devuelve JSON; el front (web/móvil) pinta los charts. Así el usuario
   ve las gráficas en línea sin depender de QuickSight.

QuickSight queda como **opción de evolución** documentada, no como recurso.

### Shield — NO es un archivo Terraform
- **Shield Standard** (el del diagrama): automático y **gratuito**; AWS lo aplica
  a CloudFront y Route 53 sin provisionar nada. No hay recurso que crear.
- **Shield Advanced**: sí es gestionable (`aws_shield_protection`) pero cuesta
  ~$3.000/mes con compromiso anual. **Descartado.**

En `edge.tf` (capa 6) irá solo como comentario aclaratorio. Es normal que **el
diagrama y el IaC no sean 1:1**: Shield Standard está en el diagrama y no en el
código; `random_password`, subnet groups, etc. están en el código y no en el
diagrama.

---

## Backend y estado

**Backend LOCAL** (decisión del reto): el estado queda en `./terraform.tfstate`.
No hay bloque `backend`, sin bucket S3 ni lock en DynamoDB. En producción se
migraría a **S3 + lock DynamoDB**. Corre siempre desde esta misma carpeta.

---

## Costos y ciclo de vida

El costo es **por hora / prorrateado**, no una cuota mensual fija. Los recursos
sin capa gratuita y siempre-encendidos son: **NAT ×2 (~$66/mes), Kinesis 6 shards
(~$66/mes), DAX ×2 (~$58/mes)**. Dejarlo todo arriba ~4 días cuesta **~$27-35**.

**Estrategia:** `terraform apply` → pruebas → `terraform destroy`. El día de la
sustentación se vuelve a hacer `apply`. Levantar con 30-40 min de anticipación
(RDS y CloudFront tardan en quedar disponibles).

`db.t4g.micro` + gp2 20 GB apuntan a la capa gratuita de RDS.

---

## Estrategia de pruebas (sin front)

- **Portal** (config alertas, estadísticas, usuarios, financiero, ventas):
  Postman/curl contra API Gateway, con un JWT de Cognito en el header
  `Authorization`.
- **Camiones** (emergencia/telemetría): entran por IoT Core vía **MQTT**, no por
  HTTP. Se simulan con el *MQTT test client* de IoT Core (o un script), publicando
  el JSON que esperan las Lambdas.

El bucket `static` + CloudFront (hosting del front) siguen en la arquitectura;
solo se omite construir/subir una app front para las pruebas del reto.

---

## Uso

```bash
terraform fmt
terraform init
terraform validate
terraform plan
terraform apply
# ... pruebas ...
terraform destroy
```

> El entorno donde se generó este código no tiene red, así que no se pudo correr
> `validate/plan`. Se revisó por inspección; correr los comandos localmente y
> ajustar si algo salta.

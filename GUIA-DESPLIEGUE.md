# Guía de despliegue — CCS Central de Monitoreo

Paso a paso para compilar las funciones Lambda (Go) y desplegar la infraestructura con Terraform.

## Estructura del proyecto

```
ccs-monitoreo-vehiculos-aws/
├── ccs-infra/                 # Infraestructura como código (Terraform)
│   ├── main.tf                # Provider y configuración base
│   ├── variables.tf           # Variables de entrada
│   ├── terraform.tfvars       # Valores reales (NO se sube a Git)
│   ├── network.tf             # VPC, subredes, NAT, security groups
│   ├── data.tf                # RDS, DynamoDB, DAX
│   ├── storage.tf             # Buckets S3
│   ├── entrada-datos.tf       # IoT Core, Kinesis, reglas de ingesta
│   ├── compute.tf             # Lambdas de emergencia y telemetría
│   ├── api.tf                 # Cognito + API Gateway + Config Alertas
│   ├── estadisticas.tf        # Endpoint de estadísticas
│   ├── rds-bootstrap.tf       # Lambda bootstrap de la base de datos
│   ├── usuarios.tf            # Endpoint de usuarios (RDS + IAM)
│   ├── financiero.tf          # Endpoint financiero (RDS + IAM)
│   ├── ventas.tf              # Step Functions + Lambdas de ventas
│   └── outputs.tf             # Salidas (endpoints, ARNs, etc.)
│
├── ccs-lambdas/               # Código Go de las funciones (una carpeta por Lambda)
│   ├── build.ps1              # Script que compila TODAS las Lambdas
│   ├── emergencia/            # main.go + go.mod
│   ├── telemetria/
│   ├── config-alertas/
│   ├── estadisticas/
│   ├── bootstrap-bd/
│   ├── usuarios/
│   ├── financiero/
│   ├── ventas-crear/
│   ├── ventas-firma/
│   └── ventas-aprobar/
│
├── Diagramas-de-Arquitectura/ # Diagramas (.drawio y .svg)
└── CCS-Presentacion.html      # Presentación (CEO + Arquitecto + evidencias)
```

> Cada carpeta dentro de `ccs-lambdas/` es un programa Go independiente con su propio
> `main.go` y `go.mod`. El `build.ps1` recorre todas y genera un `.zip` por cada una.
> Terraform toma esos `.zip` desde `../ccs-lambdas/<lambda>/<lambda>.zip`.

---

## Requisitos previos

Antes de empezar, ten instalado y configurado:

| Herramienta | Verificar con | Notas |
|---|---|---|
| **Go** (1.23+) | `go version` | Para compilar las Lambdas |
| **Terraform** (1.5+) | `terraform version` | Para desplegar la infraestructura |
| **AWS CLI** | `aws --version` | Configurado con `aws configure` en región `us-east-1` |
| **build-lambda-zip** | — | Se instala una sola vez (ver abajo) |

Credenciales AWS configuradas (usuario con permisos de administrador):

```powershell
aws configure
# AWS Access Key ID     : <tu-access-key>
# AWS Secret Access Key : <tu-secret-key>
# Default region name   : us-east-1
# Default output format  : json
```

Instala una sola vez la utilidad que empaqueta el binario Go para Lambda:

```powershell
go install github.com/aws/aws-lambda-go/cmd/build-lambda-zip@latest
```

---

## Paso 1 — Configurar las variables

En `ccs-infra/`, crea el archivo `terraform.tfvars` a partir del ejemplo y coloca tus valores
(por ejemplo, el correo que recibirá las alertas de emergencia):

```powershell
cd ccs-infra
copy terraform.tfvars.example terraform.tfvars
# edita terraform.tfvars con tu correo, etc.
```

> **Importante:** `terraform.tfvars` NO debe subirse a Git (contiene datos personales).
> Verifica que esté en el `.gitignore`.

---

## Paso 2 — Compilar las Lambdas (Go)

Desde la carpeta `ccs-lambdas/`, ejecuta el script de compilación. Recorre cada subcarpeta,
compila el `main.go` a un binario Linux/ARM64 y lo empaqueta en un `.zip`:

```powershell
cd ..\ccs-lambdas
.\build.ps1
```

Deberías ver una línea `OK -> <lambda>\<lambda>.zip` por cada función, y al final
`Listo. Zips generados.`

> Si alguna Lambda falla con *"go.mod file not found"*, esa carpeta se quedó sin su `go.mod`;
> verifica que cada carpeta tenga **dos archivos**: `main.go` y `go.mod`.

---

## Paso 3 — Inicializar Terraform (solo la primera vez)

Desde `ccs-infra/`, descarga los proveedores y prepara el directorio de trabajo:

```powershell
cd ..\ccs-infra
terraform init
```

---

## Paso 4 — Validar y revisar el plan

Comprueba que la configuración es válida y revisa qué se va a crear:

```powershell
terraform validate
terraform plan
```

`plan` muestra los recursos a crear/cambiar/destruir sin aplicar nada. Revisa que no haya errores.

---

## Paso 5 — Desplegar

Aplica la infraestructura. Terraform te mostrará el plan y pedirá confirmación:

```powershell
terraform apply
# escribe: yes
```

El despliegue tarda varios minutos (el clúster DAX y la instancia RDS son los más lentos,
~15-18 min en total). Al terminar verás `Apply complete!` y los **outputs** con los datos
que necesitas para probar:

- `api_endpoint` — URL base de la API (para Postman)
- `cognito_client_id` / `cognito_user_pool_id` — para obtener el token
- `bootstrap_resultado` — confirma que la base de datos quedó lista
- `ventas_state_machine_arn` — la máquina de estados de ventas

---

## Paso 6 — Probar

1. Publica mensajes MQTT de prueba desde la consola de **AWS IoT Core** (flujos de
   emergencia y telemetría).
2. Importa las colecciones de **Postman** y usa el `api_endpoint` como `baseUrl` para probar
   los endpoints del portal (config de alertas, estadísticas, usuarios, ventas, financiero).

---

## Actualizar una Lambda

Si cambias el código Go de una función, recompila y vuelve a aplicar. Terraform detecta el
cambio (por el hash del `.zip`) y actualiza solo esa función:

```powershell
cd ..\ccs-lambdas ; .\build.ps1
cd ..\ccs-infra ; terraform apply
```

---

## Apagar todo (evitar costos)

Cuando no estés usando el entorno, **destruye la infraestructura** para no seguir facturando
(NAT Gateways, RDS, DAX y Kinesis son los que más cuestan):

```powershell
cd ccs-infra
terraform destroy
# escribe: yes
```

Reconstruir es tan simple como repetir el Paso 2 y el Paso 5. El ciclo `destroy → apply` fue
probado: la solución completa se recrea con un comando.

> Al recrear, los buckets S3 y los endpoints tendrán nombres/URLs nuevos, las tablas estarán
> vacías, y deberás volver a confirmar la suscripción del correo (SNS).

---

## Orden de ejecución resumido

```powershell
# 1. Compilar Lambdas
cd ccs-lambdas
.\build.ps1

# 2. Desplegar infraestructura
cd ..\ccs-infra
terraform init      # solo la primera vez
terraform validate
terraform apply     # yes

# ... trabajar / presentar ...

# 3. Apagar todo al terminar
terraform destroy   # yes
```

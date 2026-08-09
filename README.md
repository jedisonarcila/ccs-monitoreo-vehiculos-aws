# CCS — Central de Monitoreo de Vehículos en AWS

Solución de arquitectura cloud para la **Compañía Colombiana de Seguimiento de Vehículos (CCS)**. Diseña e implementa una central de monitoreo capaz de recibir señales de una flota de camiones en tiempo real (ubicación, estado, video y botón de pánico), **responder emergencias en el menor tiempo posible** y soportar picos de hasta **5.000 señales por segundo**. Incluye el portal del **Plan Plus** (estadísticas, alertas, facturación y usuarios) y la **digitalización de ventas** con aprobación del Manager.

Construida 100 % **serverless** sobre AWS, definida como **infraestructura como código** (Terraform) y con las funciones en **Go**. Es una implementación de referencia **desplegada y validada en AWS como prueba de concepto funcional** (no un sistema en producción).

---

## Arquitectura en resumen

- **Recepción de señales:** AWS IoT Core recibe el MQTT de los camiones. Las reglas bifurcan el tráfico: la **emergencia** va directo a una Lambda (mínima latencia) y la **telemetría** se amortigua con **Kinesis** para absorber los picos.
- **Cómputo:** funciones **AWS Lambda** en Go, que escalan solas; el portal se expone con **API Gateway** protegido por **Cognito** (JWT + roles). Sin servidores ni balanceador que mantener.
- **Datos:** **DynamoDB** para configuración, telemetría y ventas; **RDS PostgreSQL** para usuarios y facturación, con acceso por **autenticación IAM** (sin contraseñas guardadas).
- **Orquestación de ventas:** **Step Functions** coordina el proceso y **pausa** esperando la firma del Manager para ventas de más de 50 vehículos.
- **Red:** VPC multi-AZ; solo las Lambdas que acceden a RDS corren en subred privada, el resto usa endpoints públicos + IAM.

Los diagramas (lógico y de red) están en [`Diagramas-de-Arquitectura/`](Diagramas-de-Arquitectura/).

---

## Módulos (probados end-to-end en AWS)

| Módulo | Descripción |
|---|---|
| Emergencia | Señal de pánico → acciones inmediatas → notificación por correo (SNS) |
| Telemetría | Estado del camión → Kinesis → DynamoDB |
| Config. de alertas | Portal: configuración de alertas por cliente |
| Estadísticas | Portal: distancia, tiempo y velocidades del recorrido |
| Usuarios | Portal: gestión de usuarios (RDS + IAM) |
| Ventas | Digitalización de ventas con Step Functions y firma del Manager |
| Financiero | Portal: facturación (RDS + IAM) |

---

## Despliegue

El paso a paso completo (requisitos, compilación de las Lambdas con `build.ps1`, `terraform init/apply`, pruebas y `destroy`) está en:

### 👉 [GUIA-DESPLIEGUE.md](GUIA-DESPLIEGUE.md)

Resumen rápido:

```powershell
# 1. Compilar las Lambdas (Go)
cd ccs-lambdas
.\build.ps1

# 2. Desplegar la infraestructura
cd ..\ccs-infra
terraform init      # solo la primera vez
terraform apply     # yes

# 3. Apagar todo al terminar (evita costos)
terraform destroy   # yes
```

---

## Estructura del repositorio

```
ccs-monitoreo-vehiculos-aws/
├── README.md                  # Este archivo
├── GUIA-DESPLIEGUE.md         # Guía de despliegue paso a paso
├── ccs-infra/                 # Infraestructura como código (Terraform)
├── ccs-lambdas/               # Código Go de las funciones (+ build.ps1)
├── Diagramas-de-Arquitectura/ # Diagramas (.drawio y .svg)
└── CCS-Presentacion.html      # Presentación (CEO + Arquitecto + evidencias)
```

---

## Entregables

- **Presentación:** [`CCS-Presentacion.html`](CCS-Presentacion.html) — un solo archivo con cuatro pestañas: presentación para el **CEO**, presentación para el **Arquitecto**, y las **evidencias** de infraestructura y de los flujos.
- **Diagramas:** lógico y de red, en [`Diagramas-de-Arquitectura/`](Diagramas-de-Arquitectura/).
- **Infraestructura como código:** [`ccs-infra/`](ccs-infra/).
- **Código de las funciones:** [`ccs-lambdas/`](ccs-lambdas/).

---

## Stack

`AWS` · `Terraform` · `Go` · `Serverless` · `Lambda` · `API Gateway` · `Cognito` · `IoT Core` · `Kinesis` · `DynamoDB` · `RDS PostgreSQL` · `Step Functions`

---

## Nota sobre costos

La infraestructura factura mientras está activa (NAT Gateways, RDS, DAX y Kinesis son los de mayor costo). Ejecuta `terraform destroy` cuando no la estés usando; reconstruirla es un solo `terraform apply`. El ciclo `destroy → apply` fue probado: la solución completa se recrea con un comando.

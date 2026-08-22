# Lab: Serverless (Lambda + SQS) vs Server-full (EC2 directo) — Escrituras a RDS

## Objetivo

Demostrar la **resiliencia de SQS** comparando dos arquitecturas que escriben a la misma base de datos (RDS PostgreSQL):

1. **¿Qué pasa cuando RDS se cae?** — Con SQS los mensajes esperan. Sin SQS, se pierden.
2. **¿Qué pasa con picos de escritura?** — SQS absorbe el pico. Sin SQS, saturamos el connection pool.
3. **¿Cuánto cuesta cada enfoque?** — Serverless ~$0 en reposo vs EC2+RDS siempre encendidos.

## Arquitectura

### Serverless (Lambda + SQS + RDS)

```
Clientes ──→ API Gateway ──→ Lambda Productor ──→ SQS Queue ──→ Lambda Consumidor ──→ RDS
                                                       ↓ (tras N fallos)
                                                   Dead Letter Queue
```

- SQS actúa como **buffer resiliente** entre la petición y la escritura a DB
- Si RDS se cae: mensajes quedan en SQS, se procesan cuando vuelva
- Si Lambda falla: SQS reintenta automáticamente
- Picos de tráfico: SQS absorbe sin límite, Lambda escala el consumo gradualmente

### Server-full (EC2 + RDS directo)

```
Clientes ──→ EC2 (Express, IP pública) ──→ RDS directamente
```

- Sin cola intermedia — escritura síncrona directa a la base de datos
- Si RDS se cae: error 500, la escritura se pierde
- Picos de tráfico: connection pool se agota, requests fallan

## Estructura del Proyecto

```
├── serverless/
│   ├── terraform/
│   │   ├── main.tf              # Provider AWS
│   │   ├── variables.tf         # Variables configurables
│   │   ├── outputs.tf           # URLs y ARNs útiles
│   │   ├── lambda.tf            # Lambdas (productor + consumidor)
│   │   ├── sqs.tf               # Cola SQS + DLQ
│   │   ├── api_gateway.tf       # API Gateway HTTP
│   │   ├── rds.tf               # RDS PostgreSQL (compartida)
│   │   └── iam.tf               # Roles IAM
│   └── src/
│       ├── producer/index.js    # Recibe request → envía a SQS
│       └── consumer/index.js    # Lee de SQS → escribe en RDS
│
├── server-full/
│   ├── terraform/
│   │   ├── main.tf              # Provider AWS
│   │   ├── variables.tf         # Variables configurables
│   │   ├── outputs.tf           # IP pública, endpoint RDS
│   │   ├── vpc.tf               # VPC simple (1 subnet pública)
│   │   ├── ec2.tf               # 1 EC2 pública con Express
│   │   └── rds.tf               # RDS PostgreSQL
│   │   └── userdata/
│   │       └── api.sh           # Bootstrapping de la instancia
│   └── src/
│       └── server.js            # Express → escribe directo a RDS
│
└── README.md
```

## Pruebas de Resiliencia

### Test 1: Pico de escrituras concurrentes
```bash
# Instalar Apache Bench o k6
# Enviar 1000 requests concurrentes a ambos endpoints

# Serverless
ab -n 1000 -c 100 -p payload.json -T "application/json" \
  https://<api-gateway-url>/orders

# Server-full
ab -n 1000 -c 100 -p payload.json -T "application/json" \
  http://<ec2-public-ip>:3000/orders
```

### Test 2: Simular caída de RDS
```bash
# Detener RDS temporalmente desde la consola AWS o CLI
aws rds stop-db-instance --db-instance-identifier orders-lab-db

# Enviar requests a ambos endpoints y observar:
# - Serverless: 202 Accepted (mensajes quedan en SQS esperando)
# - Server-full: 500 Error (escrituras perdidas)

# Reactivar RDS
aws rds start-db-instance --db-instance-identifier orders-lab-db
# Serverless: mensajes en SQS se procesan automáticamente
```

### Test 3: Ver la DLQ en acción
```bash
# Revisar mensajes en Dead Letter Queue (mensajes que fallaron 3 veces)
aws sqs receive-message --queue-url <dlq-url> --max-number-of-messages 10
```

## Costos Estimados (us-east-1)

| Recurso | Serverless | Server-full |
|---------|-----------|-------------|
| Compute | Lambda: $0 en reposo | EC2 t3.micro: ~$8/mes |
| Base de datos | RDS db.t3.micro: ~$13/mes | RDS db.t3.micro: ~$13/mes |
| Cola/Buffer | SQS: ~$0.40/millón msgs | N/A (no tiene) |
| API | API Gateway: ~$1/millón req | Incluido en EC2 |
| Networking | Mínimo | VPC + IP pública: ~$4/mes |
| **Total (reposo)** | **~$13/mes** (solo RDS) | **~$25/mes** |
| **Total (tráfico bajo)** | **~$14/mes** | **~$25/mes** |

## Despliegue

```bash
# Serverless
cd serverless/terraform
terraform init && terraform apply

# Server-full
cd server-full/terraform
terraform init && terraform apply
```

## Limpieza

```bash
cd serverless/terraform && terraform destroy
cd server-full/terraform && terraform destroy
```

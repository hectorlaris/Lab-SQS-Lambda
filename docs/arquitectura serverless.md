# Flujo principal (síncrono → asíncrono):

1. El cliente hace POST /orders al API Gateway HTTP (con CORS e integración AWS_PROXY).
2. API Gateway invoca la Lambda Producer (fuera de VPC, porque SQS es un servicio público).
3. El Producer hace SendMessage a la cola orders-queue.
4. El Event Source Mapping (polling automático de AWS) entrega lotes de 5 mensajes a la Lambda Consumer.
5. El Consumer inserta en RDS PostgreSQL (puerto 5432, dentro de la VPC).


# Resiliencia y desacoplamiento:

orders-queue tiene maxReceiveCount = 3; tras 3 fallos los mensajes caen a la DLQ (retención 14 días).
El Consumer usa ReportBatchItemFailures para reintentos parciales.
Red (VPC):

La Consumer vive en subnets privadas con un SG propio; RDS acepta 5432 solo desde ese SG.
Como la Consumer está en VPC, usa VPC Endpoints de tipo Interface para alcanzar SQS (DeleteMessage) y CloudWatch Logs sin salir a internet.

# IAM y observabilidad:

Roles con permisos mínimos: el producer solo sqs:SendMessage; el consumer Receive/Delete + permisos de ENI para VPC.
Cada Lambda tiene su Log Group con retención de 7 días.
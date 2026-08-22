# Demo: Serverless (Lambda + SQS) vs Server-full (EC2 directo)

## Contexto para el compañero

Este lab demuestra por qué SQS es valioso como buffer resiliente entre una API y una base de datos. Desplegamos el **mismo servicio** (registro de órdenes en PostgreSQL) de dos formas:

- **Serverless**: API Gateway → Lambda → SQS → Lambda → RDS
- **Server-full**: EC2 (Express) → RDS directamente

La pregunta clave: **¿Qué pasa con tus órdenes cuando la base de datos se cae?**

---

## Endpoints (verificar que estén activos)

```bash
# Serverless
curl -s https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders

# Server-full
curl -s http://100.56.100.104:3000/health
```

> Si los endpoints no responden, las RDS pueden estar detenidas. Activarlas:
> ```bash
> aws rds start-db-instance --db-instance-identifier orders-lab-sls-db --profile camilo-labs --region us-east-1
> aws rds start-db-instance --db-instance-identifier orders-lab-full-db --profile camilo-labs --region us-east-1
> ```
> Esperar ~5 min a que estén en "available".

---

## Test 1: Operación normal — ambos funcionan

Mostrar que ambos endpoints aceptan órdenes:

```bash
# Serverless → responde 202 (aceptado, procesamiento asíncrono)
curl -s -X POST https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "laptop", "quantity": 1, "customer": "demo@example.com"}' | python3 -m json.tool

# Server-full → responde 201 (procesado y guardado inmediatamente)
curl -s -X POST http://100.56.100.104:3000/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "laptop", "quantity": 1, "customer": "demo@example.com"}' | python3 -m json.tool
```

**Explicar**: Ambos logran lo mismo. La diferencia es que serverless responde "recibido" (202) y procesa después, mientras server-full espera a que la DB confirme (201).

---

## Test 2: Caída de RDS — aquí se ve la diferencia

### Paso 1: Apagar ambas RDS

```bash
aws rds stop-db-instance --db-instance-identifier orders-lab-sls-db --profile camilo-labs --region us-east-1
aws rds stop-db-instance --db-instance-identifier orders-lab-full-db --profile camilo-labs --region us-east-1
```

Esperar ~2-3 min hasta que ambas estén en "stopped":

```bash
aws rds describe-db-instances --db-instance-identifier orders-lab-sls-db --profile camilo-labs --region us-east-1 --query 'DBInstances[0].DBInstanceStatus' --output text
aws rds describe-db-instances --db-instance-identifier orders-lab-full-db --profile camilo-labs --region us-east-1 --query 'DBInstances[0].DBInstanceStatus' --output text
```

### Paso 2: Enviar órdenes con la DB caída

```bash
echo ""
echo "=== SERVERLESS (RDS caída) ==="
curl -s -X POST https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "orden-importante", "quantity": 1, "customer": "cliente-vip@example.com"}' | python3 -m json.tool

echo ""
echo "=== SERVER-FULL (RDS caída) ==="
curl -s -X POST http://100.56.100.104:3000/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "orden-importante", "quantity": 1, "customer": "cliente-vip@example.com"}' | python3 -m json.tool
```

**Resultado esperado**:
- Serverless: `202 Accepted` — "Orden recibida y encolada para procesamiento"
- Server-full: `500 Error` — "Esta orden se PERDIÓ"

### Paso 3: Verificar que SQS tiene los mensajes

```bash
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-queue \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --profile camilo-labs --region us-east-1 --query 'Attributes' --output json
```

**Explicar**: Los mensajes están seguros en SQS. Cuando RDS vuelva, se procesan automáticamente. En server-full, la orden se perdió para siempre.

### Paso 4: Reactivar RDS y ver el procesamiento automático

```bash
aws rds start-db-instance --db-instance-identifier orders-lab-sls-db --profile camilo-labs --region us-east-1
aws rds start-db-instance --db-instance-identifier orders-lab-full-db --profile camilo-labs --region us-east-1
```

Esperar ~5 min, luego verificar que la cola se vació (mensajes procesados):

```bash
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-queue \
  --attribute-names ApproximateNumberOfMessages \
  --profile camilo-labs --region us-east-1 --query 'Attributes.ApproximateNumberOfMessages' --output text
```

Si muestra "0" → los mensajes se procesaron automáticamente sin intervención.

---

## Test 3: Dead Letter Queue (mensajes envenenados)

**Concepto**: ¿Qué pasa si un mensaje NUNCA puede procesarse? (datos corruptos, bug en el código, etc.)

Nuestro consumer está programado para fallar siempre con productos que empiecen con `dlq-force`.

### Paso 1: Enviar mensajes que siempre fallan

```bash
# Estos SIEMPRE fallan en el consumer
curl -s -X POST https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "dlq-force-demo1", "quantity": 1, "customer": "demo@example.com"}' | python3 -m json.tool

curl -s -X POST https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "dlq-force-demo2", "quantity": 1, "customer": "demo@example.com"}' | python3 -m json.tool

# Este SÍ se procesa normalmente (comparación)
curl -s -X POST https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders \
  -H "Content-Type: application/json" \
  -d '{"product": "laptop-normal", "quantity": 1, "customer": "demo@example.com"}' | python3 -m json.tool
```

**Explicar**: Los 3 devuelven 202. El cliente no sabe cuáles fallarán. SQS gestiona los reintentos internamente.

### Paso 2: Esperar ~3-4 minutos

SQS reintenta cada 60s (VisibilityTimeout). Tras 3 intentos fallidos (maxReceiveCount=3), mueve el mensaje a la DLQ.

### Paso 3: Verificar la DLQ

```bash
echo "--- Cola principal (debería estar vacía) ---"
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-queue \
  --attribute-names ApproximateNumberOfMessages \
  --profile camilo-labs --region us-east-1 --query 'Attributes.ApproximateNumberOfMessages' --output text

echo ""
echo "--- Dead Letter Queue (mensajes fallidos) ---"
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-dlq \
  --attribute-names ApproximateNumberOfMessages \
  --profile camilo-labs --region us-east-1 --query 'Attributes.ApproximateNumberOfMessages' --output text

echo ""
echo "--- Contenido de la DLQ ---"
aws sqs receive-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-dlq \
  --max-number-of-messages 5 \
  --profile camilo-labs --region us-east-1 \
  --query 'Messages[*].Body' --output json
```

**Resultado esperado**:
- Cola principal: 0 mensajes
- DLQ: 2 mensajes (los `dlq-force-*`)
- El `laptop-normal` se procesó exitosamente

**Explicar**: Los mensajes NO se pierden. Van a una cola separada donde un operador puede investigar, corregir el bug, y hacer redrive (reenviar a la cola principal).

### Paso 4 (opcional): Redrive desde consola

Pueden ir a la consola AWS → SQS → orders-lab-sls-orders-dlq → "Start DLQ redrive" para reenviar los mensajes a la cola principal.

---

## Resumen para la presentación

| Escenario | Server-full | Serverless + SQS |
|-----------|-------------|-------------------|
| Operación normal | ✓ Escribe directo (rápido) | ✓ Encola y procesa async |
| DB se cae | ✗ Error 500, orden PERDIDA | ✓ Mensaje seguro en SQS |
| DB vuelve | ✗ Necesita reenvío manual | ✓ Procesamiento automático |
| Mensaje envenenado | ✗ Error 500, se pierde | ✓ Va a DLQ para investigación |
| Pico de tráfico | ✗ Pool saturado, fallos | ✓ SQS absorbe el pico |
| Costo en reposo | ~$25/mes (EC2+RDS 24/7) | ~$13/mes (solo RDS) |

## Conceptos clave de SQS

1. **VisibilityTimeout** (60s): Tiempo que un mensaje es invisible mientras se procesa
2. **maxReceiveCount** (3): Intentos antes de mover a DLQ
3. **Dead Letter Queue**: Cola de mensajes fallidos — no se pierden
4. **Redrive**: Capacidad de reenviar mensajes de DLQ a la cola principal
5. **Event Source Mapping**: AWS hace el polling de SQS → invoca Lambda automáticamente
6. **Desacoplamiento**: Producer y consumer son independientes

## Limpieza (cuando terminen)

```bash
cd serverless/terraform && terraform destroy -auto-approve
cd ../../server-full/terraform && terraform destroy -auto-approve
aws ec2 delete-key-pair --key-name orders-lab-key --profile camilo-labs --region us-east-1
```

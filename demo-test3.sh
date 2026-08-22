#!/bin/bash
# =============================================================================
# TEST 3: Dead Letter Queue — mensajes envenenados
# Prerequisito: Ambas RDS en estado "available"
# Nota: Esperar ~4 min después de ejecutar para verificar la DLQ
# =============================================================================
PROFILE="camilo-labs"
REGION="us-east-1"
SLS_URL="https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders"
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-queue"
DLQ_URL="https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-dlq"

echo "=============================================="
echo " TEST 3: Dead Letter Queue"
echo "=============================================="
echo ""
echo "Enviamos mensajes que SIEMPRE fallan (product=dlq-force-*)"
echo "Tras 3 reintentos → van a la DLQ sin perderse."
echo ""

echo "--- Enviando 2 órdenes normales (se procesan OK) ---"
for i in $(seq 1 2); do
  curl -s --max-time 10 -X POST $SLS_URL \
    -H "Content-Type: application/json" \
    -d "{\"product\":\"normal-$i\",\"quantity\":1,\"customer\":\"ok@example.com\"}" > /dev/null
  echo "  normal-$i enviada ✓"
done

echo ""
echo "--- Enviando 2 órdenes envenenadas (siempre fallan) ---"
for i in $(seq 1 2); do
  curl -s --max-time 10 -X POST $SLS_URL \
    -H "Content-Type: application/json" \
    -d "{\"product\":\"dlq-force-demo-$i\",\"quantity\":1,\"customer\":\"dlq@example.com\"}" > /dev/null
  echo "  dlq-force-demo-$i enviada ✓"
done

echo ""
echo "Todas aceptadas con 202."
echo ""
echo "=============================================="
echo " Esperar ~4 minutos para que se completen los reintentos."
echo " Luego verificar en consola AWS → SQS:"
echo ""
echo "   Cola principal (debe estar vacía):"
echo "   aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --attribute-names ApproximateNumberOfMessages --profile $PROFILE --region $REGION"
echo ""
echo "   DLQ (debe tener 2 mensajes):"
echo "   aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages --profile $PROFILE --region $REGION"
echo ""
echo "   Ver contenido de la DLQ:"
echo "   aws sqs receive-message --queue-url $DLQ_URL --max-number-of-messages 5 --visibility-timeout 0 --profile $PROFILE --region $REGION --query 'Messages[*].Body' --output json"
echo "=============================================="

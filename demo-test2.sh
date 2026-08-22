#!/bin/bash
# =============================================================================
# TEST 2: Caída de RDS — resiliencia de SQS
# Prerequisito: Ambas RDS en estado "stopped" (detenerlas manualmente antes)
# =============================================================================
PROFILE="camilo-labs"
REGION="us-east-1"
SLS_URL="https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders"
FULL_URL="http://100.56.100.104:3000/orders"
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-queue"

echo "=============================================="
echo " TEST 2: RDS caída — ¿Qué pasa con las órdenes?"
echo "=============================================="

echo ""
echo "--- SERVERLESS: Enviando órdenes (RDS caída) ---"
echo "    Expectativa: 202 Accepted — seguras en SQS"
echo ""
for i in $(seq 1 3); do
  echo -n "  Orden $i: "
  curl -s --max-time 10 -X POST $SLS_URL \
    -H "Content-Type: application/json" \
    -d "{\"product\":\"orden-vip-$i\",\"quantity\":$i,\"customer\":\"vip@empresa.com\"}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',d.get('error','')))"
  sleep 1
done

echo ""
echo "--- SERVER-FULL: Enviando órdenes (RDS caída) ---"
echo "    Expectativa: 500 Error — órdenes PERDIDAS"
echo ""
for i in $(seq 1 3); do
  echo -n "  Orden $i: "
  RESULT=$(curl -s --max-time 10 -X POST $FULL_URL \
    -H "Content-Type: application/json" \
    -d "{\"product\":\"orden-vip-$i\",\"quantity\":$i,\"customer\":\"vip@empresa.com\"}" 2>/dev/null)
  if [ -z "$RESULT" ]; then
    echo "SIN RESPUESTA (servidor caído)"
  else
    echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d.get(\"error\",d.get(\"message\",\"\"))} → {d.get(\"note\",\"\")}')" 2>/dev/null || echo "$RESULT"
  fi
done

echo ""
echo "--- Mensajes en SQS (seguros, esperando RDS) ---"
aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --profile $PROFILE --region $REGION \
  --query 'Attributes' --output json

echo ""
echo "=============================================="
echo " RESULTADO:"
echo "   Serverless: órdenes SEGURAS en SQS"
echo "   Server-full: órdenes PERDIDAS (error 500)"
echo ""
echo " Siguiente paso: reactivar RDS y verificar que"
echo " SQS procesa automáticamente (cola llega a 0)"
echo "=============================================="

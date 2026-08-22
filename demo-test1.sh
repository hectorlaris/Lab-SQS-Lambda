#!/bin/bash
# =============================================================================
# TEST 1: Carga concurrente — ambos endpoints funcionando
# Prerequisito: Ambas RDS en estado "available"
# =============================================================================
SLS_URL="https://fbi68opr77.execute-api.us-east-1.amazonaws.com/orders"
FULL_URL="http://100.56.100.104:3000/orders"
PROFILE="camilo-labs"
REGION="us-east-1"
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/332782539326/orders-lab-sls-orders-queue"

echo "=============================================="
echo " TEST 1: Carga concurrente (30 requests, 10 en paralelo)"
echo "=============================================="

echo ""
echo "--- Server-full (EC2 → RDS directo) ---"
START=$(date +%s%N)
for batch in $(seq 1 3); do
  for i in $(seq 1 10); do
    (
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST $FULL_URL \
        -H "Content-Type: application/json" \
        -d "{\"product\":\"carga-full-${batch}-${i}\",\"quantity\":1,\"customer\":\"load@test.com\"}")
      echo "$STATUS" >> /tmp/full_results.txt
    ) &
  done
  wait
done
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
OK=$(grep -c "201" /tmp/full_results.txt 2>/dev/null || echo 0)
FAIL=$(grep -vc "201" /tmp/full_results.txt 2>/dev/null || echo 0)
rm -f /tmp/full_results.txt

echo "  Tiempo: ${ELAPSED}ms"
echo "  Exitosos (201): $OK / 30"
echo "  Fallidos: $FAIL"

echo ""
echo "--- Serverless (Lambda → SQS → RDS) ---"
START=$(date +%s%N)
for batch in $(seq 1 3); do
  for i in $(seq 1 10); do
    (
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST $SLS_URL \
        -H "Content-Type: application/json" \
        -d "{\"product\":\"carga-sls-${batch}-${i}\",\"quantity\":1,\"customer\":\"load@test.com\"}")
      echo "$STATUS" >> /tmp/sls_results.txt
    ) &
  done
  wait
done
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
OK=$(grep -c "202" /tmp/sls_results.txt 2>/dev/null || echo 0)
FAIL=$(grep -vc "202" /tmp/sls_results.txt 2>/dev/null || echo 0)
rm -f /tmp/sls_results.txt

echo "  Tiempo: ${ELAPSED}ms"
echo "  Exitosos (202): $OK / 30"
echo "  Fallidos: $FAIL"

echo ""
echo "--- Esperando 15s para que SQS procese ---"
sleep 15

echo ""
echo "--- Cola SQS (debería estar en 0) ---"
aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --profile $PROFILE --region $REGION \
  --query 'Attributes' --output json

echo ""
echo "--- Stats Server-full (pool de conexiones) ---"
curl -s http://100.56.100.104:3000/stats | python3 -m json.tool

echo ""
echo "=============================================="
echo " OBSERVACIONES:"
echo "   - Server-full: más rápido (escritura síncrona)"
echo "   - Serverless: puede tener 503 en cold start"
echo "   - Con más carga, server-full satura pool (max 10)"
echo "   - Serverless: SQS absorbe sin límite"
echo "=============================================="

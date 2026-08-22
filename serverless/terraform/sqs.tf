# =============================================================================
# SQS — Cola principal + Dead Letter Queue
# =============================================================================
#
# ESTE es el componente clave del lab. SQS proporciona:
#
# 1. RESILIENCIA: Si RDS cae, mensajes esperan en cola (no se pierden)
# 2. BUFFER: Absorbe picos de tráfico sin saturar la DB
# 3. REINTENTOS: maxReceiveCount controla cuántas veces se reintenta
# 4. DLQ: Mensajes "envenenados" van a cola separada para investigación
# 5. DESACOPLAMIENTO: Productor y consumidor no se conocen
#
# Flujo:
#   Lambda Productor → orders_queue → Lambda Consumidor → RDS
#                           ↓ (tras 3 fallos)
#                       orders_dlq

# Dead Letter Queue — donde van los mensajes que fallaron N veces
resource "aws_sqs_queue" "orders_dlq" {
  name                      = "${var.project_name}-orders-dlq"
  message_retention_seconds = 1209600 # 14 días para investigar

  tags = { Name = "${var.project_name}-orders-dlq" }
}

# Cola principal
resource "aws_sqs_queue" "orders_queue" {
  name                       = "${var.project_name}-orders-queue"
  visibility_timeout_seconds = var.sqs_visibility_timeout
  message_retention_seconds  = var.sqs_message_retention
  receive_wait_time_seconds  = 20 # Long polling (reduce costos)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })

  tags = { Name = "${var.project_name}-orders-queue" }
}

resource "aws_sqs_queue_redrive_allow_policy" "orders_dlq_allow" {
  queue_url = aws_sqs_queue.orders_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders_queue.arn]
  })
}

# =============================================================================
# Lambda Functions — Productor y Consumidor
# =============================================================================

# --- Empaquetar código ---
data "archive_file" "producer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/producer"
  output_path = "${path.module}/../dist/producer.zip"
}

data "archive_file" "consumer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/consumer"
  output_path = "${path.module}/../dist/consumer.zip"
}

# --- Lambda Productor ---
# Recibe HTTP → envía a SQS (NO necesita VPC, SQS es servicio público)
resource "aws_lambda_function" "producer" {
  function_name = "${var.project_name}-producer"
  role          = aws_iam_role.producer_role.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory

  filename         = data.archive_file.producer_zip.output_path
  source_code_hash = data.archive_file.producer_zip.output_base64sha256

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.orders_queue.url
    }
  }
}

# --- Lambda Consumidor ---
# Lee de SQS → escribe en RDS
resource "aws_lambda_function" "consumer" {
  function_name = "${var.project_name}-consumer"
  role          = aws_iam_role.consumer_role.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory

  filename         = data.archive_file.consumer_zip.output_path
  source_code_hash = data.archive_file.consumer_zip.output_base64sha256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST     = aws_db_instance.postgres.address
      DB_PORT     = tostring(aws_db_instance.postgres.port)
      DB_NAME     = "orders"
      DB_USER     = "labuser"
      DB_PASSWORD = var.db_password
    }
  }
}

# --- Event Source Mapping ---
# Conexión SQS → Lambda (AWS hace el polling automáticamente)
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = aws_sqs_queue.orders_queue.arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = var.consumer_batch_size
  enabled          = true

  function_response_types = ["ReportBatchItemFailures"]
}

# --- CloudWatch Logs ---
resource "aws_cloudwatch_log_group" "producer_logs" {
  name              = "/aws/lambda/${aws_lambda_function.producer.function_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "consumer_logs" {
  name              = "/aws/lambda/${aws_lambda_function.consumer.function_name}"
  retention_in_days = 7
}

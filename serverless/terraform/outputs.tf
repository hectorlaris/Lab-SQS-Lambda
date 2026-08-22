output "api_url" {
  description = "URL del endpoint serverless (POST /orders)"
  value       = "${aws_apigatewayv2_api.orders_api.api_endpoint}/orders"
}

output "sqs_queue_url" {
  description = "URL de la cola SQS (para monitoreo)"
  value       = aws_sqs_queue.orders_queue.url
}

output "dlq_url" {
  description = "URL de la Dead Letter Queue"
  value       = aws_sqs_queue.orders_dlq.url
}

output "rds_endpoint" {
  description = "Endpoint de RDS"
  value       = aws_db_instance.postgres.address
}

output "test_command" {
  description = "Comando para probar"
  value       = <<-EOT
    curl -X POST ${aws_apigatewayv2_api.orders_api.api_endpoint}/orders \
      -H "Content-Type: application/json" \
      -d '{"product": "laptop", "quantity": 1, "customer": "juan@example.com"}'
  EOT
}

output "check_queue_depth" {
  description = "Ver mensajes pendientes en SQS"
  value       = "aws sqs get-queue-attributes --queue-url ${aws_sqs_queue.orders_queue.url} --attribute-names ApproximateNumberOfMessages"
}

output "check_dlq" {
  description = "Ver mensajes en DLQ (fallidos)"
  value       = "aws sqs get-queue-attributes --queue-url ${aws_sqs_queue.orders_dlq.url} --attribute-names ApproximateNumberOfMessages"
}

output "load_test_command" {
  description = "Prueba de carga"
  value       = <<-EOT
    echo '{"product":"laptop","quantity":1,"customer":"test@example.com"}' > /tmp/payload.json
    ab -n 500 -c 50 -p /tmp/payload.json -T "application/json" \
      ${aws_apigatewayv2_api.orders_api.api_endpoint}/orders
  EOT
}

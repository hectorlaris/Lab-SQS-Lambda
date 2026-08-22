output "ec2_public_ip" {
  description = "IP pública de la EC2 (endpoint directo)"
  value       = aws_instance.api_server.public_ip
}

output "api_url" {
  description = "URL para enviar órdenes"
  value       = "http://${aws_instance.api_server.public_ip}:3000/orders"
}

output "health_url" {
  description = "URL del health check"
  value       = "http://${aws_instance.api_server.public_ip}:3000/health"
}

output "rds_endpoint" {
  description = "Endpoint de RDS PostgreSQL"
  value       = aws_db_instance.postgres.address
}

output "test_command" {
  description = "Comando para probar"
  value       = <<-EOT
    curl -X POST http://${aws_instance.api_server.public_ip}:3000/orders \
      -H "Content-Type: application/json" \
      -d '{"product": "laptop", "quantity": 1, "customer": "juan@example.com"}'
  EOT
}

output "load_test_command" {
  description = "Comando para prueba de carga (instalar ab: apt install apache2-utils)"
  value       = <<-EOT
    echo '{"product":"laptop","quantity":1,"customer":"test@example.com"}' > /tmp/payload.json
    ab -n 500 -c 50 -p /tmp/payload.json -T "application/json" \
      http://${aws_instance.api_server.public_ip}:3000/orders
  EOT
}

# =============================================================================
# Lambda Checker — Consulta de verificacion contra RDS
# =============================================================================
# Herramienta SOLO para el lab: RDS esta en subnets privadas, asi que no se
# puede consultar desde fuera de la VPC. Esta Lambda vive en las mismas subnets
# que el consumer y ejecuta SELECTs de solo lectura sobre la tabla `orders`.
#
# Se invoca manualmente (sin trigger). El script check-db.ps1 la llama.
# Para eliminarla al terminar el lab: borra este archivo y aplica de nuevo,
# o usa: terraform destroy -target=aws_lambda_function.checker ...

# --- Empaquetar codigo del checker (incluye node_modules con pg) ---
data "archive_file" "checker_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/checker"
  output_path = "${path.module}/../dist/checker.zip"
}

# --- Rol IAM del checker ---
# Mismo patron que el consumer: necesita acceso a VPC (ENIs) y logs.
# NO necesita permisos de SQS (solo lee RDS).
resource "aws_iam_role" "checker_role" {
  name = "${var.project_name}-checker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "checker_policy" {
  name = "${var.project_name}-checker-policy"
  role = aws_iam_role.checker_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "VPCAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- Lambda Checker ---
# En las mismas subnets privadas y SG que el consumer, para alcanzar RDS.
resource "aws_lambda_function" "checker" {
  function_name = "${var.project_name}-checker"
  role          = aws_iam_role.checker_role.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.checker_zip.output_path
  source_code_hash = data.archive_file.checker_zip.output_base64sha256

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

resource "aws_cloudwatch_log_group" "checker_logs" {
  name              = "/aws/lambda/${aws_lambda_function.checker.function_name}"
  retention_in_days = 7
}

output "checker_function_name" {
  description = "Nombre de la Lambda de verificacion (invocar con check-db.ps1)"
  value       = aws_lambda_function.checker.function_name
}

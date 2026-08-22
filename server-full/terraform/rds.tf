# =============================================================================
# RDS PostgreSQL — Base de datos para escritura directa
# =============================================================================
# Misma DB que usará la versión serverless para comparación justa.

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.project_name}-db"
  engine         = "postgres"
  engine_version = "15"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"

  db_name  = "orders"
  username = "labuser"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Lab settings — NO para producción
  skip_final_snapshot = true
  deletion_protection = false
  backup_retention_period = 0

  tags = {
    Name = "${var.project_name}-db"
  }
}

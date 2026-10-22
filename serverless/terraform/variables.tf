variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto (prefijo para recursos)"
  type        = string
  default     = "orders-lab-sls"
}

variable "aws_profile" {
  description = "profile para hacer ela provisionamiento"
  type        = string
  default     = "hserrano-aws-v2"
}

# --- SQS ---

variable "sqs_visibility_timeout" {
  description = "Segundos que un mensaje es invisible tras ser recibido. Debe ser > lambda_timeout."
  type        = number
  default     = 60
}

variable "sqs_message_retention" {
  description = "Segundos que SQS retiene un mensaje (máx 1209600 = 14 días)"
  type        = number
  default     = 86400
}

variable "sqs_max_receive_count" {
  description = "Intentos antes de enviar a DLQ"
  type        = number
  default     = 3
}

# --- Lambda ---

variable "lambda_timeout" {
  description = "Timeout de Lambda (segundos). Consumidor debe ser < sqs_visibility_timeout."
  type        = number
  default     = 30
}

variable "lambda_memory" {
  description = "Memoria de Lambda (MB)"
  type        = number
  default     = 128
}

variable "consumer_batch_size" {
  description = "Mensajes por invocación del consumidor (1-10)"
  type        = number
  default     = 5
}

# --- RDS ---

variable "db_instance_class" {
  description = "Clase de instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_password" {
  description = "Contraseña para RDS"
  type        = string
  sensitive   = true
}

# --- VPC ---

variable "vpc_cidr" {
  description = "CIDR de la VPC"
  type        = string
  default     = "10.1.0.0/16"
}

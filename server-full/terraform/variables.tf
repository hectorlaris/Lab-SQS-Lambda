variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto (prefijo para recursos)"
  type        = string
  default     = "orders-lab-full"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "Clase de instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_password" {
  description = "Contraseña para el usuario de RDS"
  type        = string
  sensitive   = true
}

variable "key_pair_name" {
  description = "Key Pair para SSH (debe existir previamente, dejar vacío para deshabilitar SSH)"
  type        = string
  default     = ""
}

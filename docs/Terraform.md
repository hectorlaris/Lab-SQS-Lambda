----
perfiles disponibles son:

    AdministratorAccess-962682390364
    DeveloperFullAccess-962682390364
    DeveloperLoanWorkflow-962682390364
    EC2Admin-962682390364
    DeveloperAccess-962682390364
    hserrano-aws-v2
    cliuser
    default

----

# main.tf

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
  ...
}

# commnds
terrafor init 
terrafor pla 

terrafor apply 
terraform apply -var="aws_profile=hserrano-aws-v2"

terrafor destroy 

# verification

## 1. Desde Terraform (su estado)
### Lista todos los recursos que Terraform gestiona
terraform state list

### Muestra los outputs definidos (URLs, ARNs, endpoints, etc.)
terraform output

### Detalle completo de un recurso concreto
terraform state show aws_sqs_queue.<nombre>

### Confirma que no hay diferencias entre el estado y la realidad
terraform plan


## 2. Desde AWS directamente (la realidad)

### SQS: lista las colas
aws sqs list-queues --profile <perfil> --region <region>

### Lambda: lista las funciones (producer y consumer)
aws lambda list-functions --profile <perfil> --region <region> --query "Functions[].FunctionName"

### API Gateway v2 (HTTP API)
aws apigatewayv2 get-apis --profile <perfil> --region <region> --query "Items[].{Name:Name,Endpoint:ApiEndpoint}"

### RDS
aws rds describe-db-instances --profile <perfil> --region <region> --query "DBInstances[].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address}"

### SQS: mensajes pendientes en la cola (que tu output ya te da el comando exacto)
aws sqs get-queue-attributes --queue-url <url-de-la-cola> --attribute-names ApproximateNumberOfMessages --profile <perfil> --region <region>





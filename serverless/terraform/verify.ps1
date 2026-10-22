<#
.SYNOPSIS
    Verifica los servicios aprovisionados por Terraform para el lab SQS + Lambda.

.DESCRIPTION
    Revisa dos niveles:
      1) Estado de Terraform (state list, output, plan de deriva).
      2) Realidad en AWS (SQS, Lambda, API Gateway, RDS, VPC endpoints).
    Toma la region y los nombres desde `terraform output`, asi nunca se
    desincroniza del despliegue real.

.PARAMETER Profile
    Perfil de AWS a usar. Por defecto el mismo que usa Terraform (hserrano-aws-v2).

.PARAMETER SkipPlan
    Omite `terraform plan` (el chequeo mas lento) si solo quieres el inventario.

.EXAMPLE
    ./verify.ps1
    ./verify.ps1 -Profile AdministratorAccess-962682390364
    ./verify.ps1 -SkipPlan
#>

[CmdletBinding()]
param(
    [string]$Profile = "hserrano-aws-v2",
    [switch]$SkipPlan
)

$ErrorActionPreference = "Stop"

# --- Helpers de salida --------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK]  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!!]  $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [XX]  $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

# --- Prerrequisitos -----------------------------------------------------------

Write-Section "Prerrequisitos"

foreach ($tool in @("terraform", "aws")) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if ($found) {
        Write-Ok "$tool disponible"
    }
    else {
        Write-Fail "$tool no esta en el PATH. Instalalo antes de continuar."
        exit 1
    }
}

Write-Info "Perfil AWS: $Profile"

# Argumentos comunes para el CLI de AWS (perfil + salida JSON)
$awsArgs = @("--profile", $Profile, "--output", "json")

# --- 1. Estado de Terraform ---------------------------------------------------

Write-Section "1. Estado de Terraform"

Write-Host "`n  -> terraform state list" -ForegroundColor White
$stateList = terraform state list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "No se pudo leer el estado. Estas en la carpeta terraform/ y ya aplicaste?"
    Write-Info ($stateList -join "`n")
    exit 1
}
$stateList | ForEach-Object { Write-Info $_ }
$resourceCount = ($stateList | Measure-Object).Count
Write-Ok "$resourceCount recursos gestionados por Terraform"

Write-Host "`n  -> terraform output" -ForegroundColor White
$outputsJson = terraform output -json | ConvertFrom-Json

# Extraer valores clave de los outputs
$region       = ($outputsJson.sqs_queue_url.value -split "\.")[1]
$queueUrl     = $outputsJson.sqs_queue_url.value
$dlqUrl       = $outputsJson.dlq_url.value
$apiUrl       = $outputsJson.api_url.value
$rdsEndpoint  = $outputsJson.rds_endpoint.value

if (-not $region) { $region = "us-east-1" }  # fallback
$awsArgs += @("--region", $region)

Write-Info "Region detectada:   $region"
Write-Info "API URL:            $apiUrl"
Write-Info "SQS Queue URL:      $queueUrl"
Write-Info "DLQ URL:            $dlqUrl"
Write-Info "RDS Endpoint:       $rdsEndpoint"

# --- 2. Verificacion contra AWS ----------------------------------------------

Write-Section "2. Servicios reales en AWS (region $region)"

# --- SQS: cola principal ---
Write-Host "`n  SQS - Cola principal" -ForegroundColor White
try {
    $attrs = aws sqs get-queue-attributes --queue-url $queueUrl `
        --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible `
        @awsArgs | ConvertFrom-Json
    $visible    = $attrs.Attributes.ApproximateNumberOfMessages
    $inflight   = $attrs.Attributes.ApproximateNumberOfMessagesNotVisible
    Write-Ok "Cola accesible"
    Write-Info "Mensajes pendientes:   $visible"
    Write-Info "Mensajes en vuelo:     $inflight"
}
catch {
    Write-Fail "No se pudo consultar la cola principal: $($_.Exception.Message)"
}

# --- SQS: DLQ ---
Write-Host "`n  SQS - Dead Letter Queue" -ForegroundColor White
try {
    $dlqAttrs = aws sqs get-queue-attributes --queue-url $dlqUrl `
        --attribute-names ApproximateNumberOfMessages @awsArgs | ConvertFrom-Json
    $dlqCount = $dlqAttrs.Attributes.ApproximateNumberOfMessages
    Write-Ok "DLQ accesible"
    if ([int]$dlqCount -gt 0) {
        Write-Warn "Hay $dlqCount mensaje(s) en la DLQ (fallidos, revisar)"
    }
    else {
        Write-Info "Mensajes fallidos:     0"
    }
}
catch {
    Write-Fail "No se pudo consultar la DLQ: $($_.Exception.Message)"
}

# --- Lambda: funciones del proyecto ---
Write-Host "`n  Lambda - Funciones" -ForegroundColor White
foreach ($fn in @("orders-lab-sls-producer", "orders-lab-sls-consumer")) {
    try {
        $fnInfo = aws lambda get-function-configuration --function-name $fn @awsArgs | ConvertFrom-Json
        Write-Ok "$fn  (runtime: $($fnInfo.Runtime), estado: $($fnInfo.State))"
    }
    catch {
        Write-Fail "No se encontro la funcion $fn"
    }
}

# --- Lambda: event source mapping (SQS -> consumer) ---
Write-Host "`n  Lambda - Event Source Mapping (SQS -> consumer)" -ForegroundColor White
try {
    $esm = aws lambda list-event-source-mappings --function-name "orders-lab-sls-consumer" @awsArgs | ConvertFrom-Json
    if ($esm.EventSourceMappings.Count -gt 0) {
        foreach ($m in $esm.EventSourceMappings) {
            Write-Ok "Mapping $($m.State) (batch size: $($m.BatchSize))"
        }
    }
    else {
        Write-Warn "No hay event source mappings para el consumer"
    }
}
catch {
    Write-Fail "No se pudieron listar los event source mappings: $($_.Exception.Message)"
}

# --- API Gateway v2 ---
Write-Host "`n  API Gateway (HTTP API)" -ForegroundColor White
try {
    $apis = aws apigatewayv2 get-apis @awsArgs | ConvertFrom-Json
    $labApi = $apis.Items | Where-Object { $apiUrl -like "*$($_.ApiId)*" }
    if ($labApi) {
        Write-Ok "API encontrada: $($labApi.Name)  ($($labApi.ProtocolType))"
        Write-Info "Endpoint: $($labApi.ApiEndpoint)"
    }
    else {
        Write-Warn "No se identifico la API del lab entre $($apis.Items.Count) API(s)"
    }
}
catch {
    Write-Fail "No se pudo consultar API Gateway: $($_.Exception.Message)"
}

# --- RDS ---
Write-Host "`n  RDS - PostgreSQL" -ForegroundColor White
try {
    $dbId = ($rdsEndpoint -split "\.")[0]
    $db = aws rds describe-db-instances --db-instance-identifier $dbId @awsArgs | ConvertFrom-Json
    $inst = $db.DBInstances[0]
    if ($inst.DBInstanceStatus -eq "available") {
        Write-Ok "RDS $($inst.DBInstanceIdentifier) - estado: $($inst.DBInstanceStatus)"
    }
    else {
        Write-Warn "RDS $($inst.DBInstanceIdentifier) - estado: $($inst.DBInstanceStatus)"
    }
    Write-Info "Engine:   $($inst.Engine) $($inst.EngineVersion)"
    Write-Info "Clase:    $($inst.DBInstanceClass)"
    Write-Info "Endpoint: $($inst.Endpoint.Address):$($inst.Endpoint.Port)"
}
catch {
    Write-Fail "No se pudo consultar RDS: $($_.Exception.Message)"
}

# --- 3. Deteccion de deriva (drift) ------------------------------------------

if (-not $SkipPlan) {
    Write-Section "3. Deteccion de deriva (terraform plan)"
    Write-Info "Comparando estado vs AWS real... (puede tardar)"
    terraform plan -detailed-exitcode -input=false -var="aws_profile=$Profile" | Out-Null
    switch ($LASTEXITCODE) {
        0 { Write-Ok "Sin cambios. La infraestructura coincide con la configuracion." }
        2 { Write-Warn "Hay deriva: el estado no coincide con AWS. Corre 'terraform plan' para ver el detalle." }
        default { Write-Fail "terraform plan fallo (exit code $LASTEXITCODE). Revisa credenciales/variables (ej. db_password)." }
    }
}
else {
    Write-Info "`n(terraform plan omitido con -SkipPlan)"
}

# --- Resumen ------------------------------------------------------------------

Write-Section "Verificacion completada"
Write-Info "Para una prueba end-to-end, envia un pedido al API:"
Write-Host "  curl -X POST $apiUrl -H `"Content-Type: application/json`" -d '{\"product\":\"laptop\",\"quantity\":1,\"customer\":\"juan@example.com\"}'" -ForegroundColor White
Write-Host ""

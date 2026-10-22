<#
.SYNOPSIS
    Consulta la tabla `orders` en RDS invocando la Lambda checker del lab.

.DESCRIPTION
    RDS esta en subnets privadas, inaccesible desde tu PC. Esta herramienta
    invoca la Lambda `orders-lab-sls-checker` (que vive dentro de la VPC) y
    muestra de forma legible:
      - Total de ordenes en la tabla
      - Desglose por status
      - Rango temporal (primera / ultima)
      - Las ultimas 5 ordenes insertadas

.PARAMETER Profile
    Perfil de AWS. Por defecto hserrano-aws-v2.

.PARAMETER Region
    Region de AWS. Por defecto us-east-1.

.PARAMETER FunctionName
    Nombre de la Lambda checker. Por defecto orders-lab-sls-checker.

.EXAMPLE
    .\check-db.ps1
    .\check-db.ps1 -Profile AdministratorAccess-962682390364
#>

[CmdletBinding()]
param(
    [string]$Profile = "hserrano-aws-v2",
    [string]$Region = "us-east-1",
    [string]$FunctionName = "orders-lab-sls-checker"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  CONSULTA A RDS via Lambda checker" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

# Archivo temporal para la respuesta de la Lambda
$outFile = Join-Path $env:TEMP "checker-response.json"

# Invocar la Lambda. --cli-binary-format evita que el CLI espere payload en base64.
aws lambda invoke `
    --function-name $FunctionName `
    --cli-binary-format raw-in-base64-out `
    --payload '{}' `
    --profile $Profile `
    --region $Region `
    $outFile | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [XX] Fallo la invocacion de la Lambda." -ForegroundColor Red
    exit 1
}

# La respuesta de la Lambda es el JSON que devuelve el handler
$result = Get-Content $outFile -Raw | ConvertFrom-Json

if (-not $result.ok) {
    Write-Host "  [XX] La consulta fallo dentro de la Lambda:" -ForegroundColor Red
    Write-Host "       $($result.error)" -ForegroundColor Red
    exit 1
}

# --- Mostrar resultados ---
Write-Host ""
Write-Host "  TOTAL de ordenes en RDS: $($result.total)" -ForegroundColor Green

Write-Host ""
Write-Host "  Desglose por status:" -ForegroundColor White
foreach ($prop in $result.byStatus.PSObject.Properties) {
    Write-Host ("    {0,-15} {1}" -f $prop.Name, $prop.Value)
}

Write-Host ""
Write-Host "  Rango temporal:" -ForegroundColor White
Write-Host "    Primera orden: $($result.oldest)"
Write-Host "    Ultima orden:  $($result.newest)"

Write-Host ""
Write-Host "  Ultimas 5 ordenes insertadas:" -ForegroundColor White
foreach ($o in $result.lastOrders) {
    Write-Host ("    [{0}] {1} x{2}  cliente={3}  ({4})" -f `
        $o.status, $o.product, $o.quantity, $o.customer, $o.created_at)
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

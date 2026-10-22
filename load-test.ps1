<#
.SYNOPSIS
    Prueba de carga concurrente para comparar las dos arquitecturas del lab:
    serverless (API Gateway + SQS + Lambda) vs server-full (EC2 + Express + RDS directo).

.DESCRIPTION
    Dispara N requests POST /orders con un nivel de concurrencia C usando runspaces
    de PowerShell (paralelismo real, no secuencial). Al final reporta:
      - Total OK / fallidos
      - Codigos HTTP agrupados
      - Latencia min / promedio / p95 / p99 / max
      - Throughput (requests/segundo)

    El contraste esperado del lab:
      - serverless: casi todo 202/200, SQS absorbe el pico, 0 perdidas.
      - server-full: al pasar de 10 conexiones concurrentes empiezan los 500
        (pool agotado) y timeouts -> ordenes PERDIDAS.

.PARAMETER Url
    Endpoint POST /orders a probar. Obligatorio.

.PARAMETER Requests
    Numero total de requests. Por defecto 1000.

.PARAMETER Concurrency
    Requests simultaneos. Por defecto 50.

.PARAMETER Label
    Etiqueta para el reporte (ej. "serverless" o "server-full").

.PARAMETER TimeoutSec
    Timeout por request en segundos. Por defecto 15.

.EXAMPLE
    # Serverless (con SQS)
    .\load-test.ps1 -Url "https://yq20559n8e.execute-api.us-east-1.amazonaws.com/orders" -Requests 1000 -Concurrency 50 -Label serverless

.EXAMPLE
    # Server-full (EC2 directo)
    .\load-test.ps1 -Url "http://<EC2_IP>:3000/orders" -Requests 1000 -Concurrency 50 -Label server-full
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [int]$Requests = 1000,

    [int]$Concurrency = 50,

    [string]$Label = "endpoint",

    [int]$TimeoutSec = 15
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  PRUEBA DE CARGA: $Label" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  URL:          $Url"
Write-Host "  Requests:     $Requests"
Write-Host "  Concurrencia: $Concurrency"
Write-Host "  Timeout:      $TimeoutSec s"
Write-Host ""

# Bloque que ejecuta cada worker en su propio runspace.
$worker = {
    param($Url, $Index, $TimeoutSec)

    $payload = @{
        product  = "laptop"
        quantity = 1
        customer = "load-test-$Index@example.com"
    } | ConvertTo-Json -Compress

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Post -Body $payload `
            -ContentType "application/json" -TimeoutSec $TimeoutSec `
            -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        [pscustomobject]@{
            Index   = $Index
            Status  = [int]$resp.StatusCode
            Ms      = $sw.Elapsed.TotalMilliseconds
            Ok      = $true
        }
    }
    catch {
        $sw.Stop()
        # Extraer el codigo HTTP si la excepcion lo trae (ej. 500, 503)
        $code = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $code = [int]$_.Exception.Response.StatusCode.value__
        }
        [pscustomobject]@{
            Index   = $Index
            Status  = $code
            Ms      = $sw.Elapsed.TotalMilliseconds
            Ok      = $false
        }
    }
}

# Pool de runspaces con el limite de concurrencia pedido.
$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()

$jobs = [System.Collections.Generic.List[object]]::new()
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 1; $i -le $Requests; $i++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($Url).AddArgument($i).AddArgument($TimeoutSec)
    $jobs.Add([pscustomobject]@{ Shell = $ps; Handle = $ps.BeginInvoke() })
}

Write-Host "  Enviando $Requests requests..." -ForegroundColor Gray

# Recolectar resultados
$results = [System.Collections.Generic.List[object]]::new()
foreach ($job in $jobs) {
    $r = $job.Shell.EndInvoke($job.Handle)
    if ($r) { $results.Add($r[0]) }
    $job.Shell.Dispose()
}

$totalSw.Stop()
$pool.Close()
$pool.Dispose()

# --- Analisis de resultados ---
$okCount   = ($results | Where-Object Ok).Count
$failCount = ($results | Where-Object { -not $_.Ok }).Count
$latencies = $results | ForEach-Object { $_.Ms } | Sort-Object

function Get-Percentile {
    param([double[]]$Sorted, [double]$P)
    if ($Sorted.Count -eq 0) { return 0 }
    $idx = [math]::Ceiling(($P / 100.0) * $Sorted.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $Sorted.Count) { $idx = $Sorted.Count - 1 }
    return $Sorted[$idx]
}

$totalSec    = $totalSw.Elapsed.TotalSeconds
$throughput  = if ($totalSec -gt 0) { [math]::Round($Requests / $totalSec, 1) } else { 0 }

Write-Host ""
Write-Host ("-" * 70) -ForegroundColor DarkGray
Write-Host "  RESULTADOS: $Label" -ForegroundColor White
Write-Host ("-" * 70) -ForegroundColor DarkGray
Write-Host ("  Duracion total:   {0:N2} s" -f $totalSec)
Write-Host ("  Throughput:       {0} req/s" -f $throughput)
Write-Host ("  Exitosos (2xx):   {0}" -f $okCount) -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host ("  Fallidos:         {0}" -f $failCount) -ForegroundColor Red
}
else {
    Write-Host ("  Fallidos:         0") -ForegroundColor Green
}

Write-Host ""
Write-Host "  Codigos HTTP:" -ForegroundColor White
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    $name = if ($_.Name -eq "0") { "sin respuesta / timeout" } else { $_.Name }
    $color = if ($_.Name -match "^2") { "Green" } elseif ($_.Name -eq "0") { "Red" } else { "Yellow" }
    Write-Host ("    {0,-24} {1}" -f $name, $_.Count) -ForegroundColor $color
}

Write-Host ""
Write-Host "  Latencia (ms):" -ForegroundColor White
if ($latencies.Count -gt 0) {
    $avg = ($latencies | Measure-Object -Average).Average
    Write-Host ("    min:  {0:N1}" -f $latencies[0])
    Write-Host ("    avg:  {0:N1}" -f $avg)
    Write-Host ("    p95:  {0:N1}" -f (Get-Percentile -Sorted $latencies -P 95))
    Write-Host ("    p99:  {0:N1}" -f (Get-Percentile -Sorted $latencies -P 99))
    Write-Host ("    max:  {0:N1}" -f $latencies[-1])
}

Write-Host ""
if ($failCount -gt 0) {
    Write-Host "  >> $failCount orden(es) se PERDIERON (no llegaron a procesarse)." -ForegroundColor Red
    Write-Host "     En la arquitectura con SQS esto deberia ser 0." -ForegroundColor Gray
}
else {
    Write-Host "  >> Todas las ordenes fueron aceptadas. Verifica que SQS/RDS las proceso." -ForegroundColor Green
}
Write-Host ""

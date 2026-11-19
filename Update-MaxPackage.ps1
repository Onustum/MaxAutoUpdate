# --- Settings ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TargetPath    = "in the GPO scripts folder"
$MsiPath       = Join-Path $TargetPath "MAX.msi"
$TempMsiPath   = Join-Path $TargetPath "MAX.msi.new"
$SourceUrl     = "https://download.max.ru/win/release/MAX.msi"
$LogFile       = Join-Path $TargetPath "update.log"
$MaxRetries    = 5
$RetryDelaySec = 60

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "$timestamp  $Message" -Encoding UTF8
}

# --- Скачивание во временный файл ---
try {
    if (Test-Path $TempMsiPath) { Remove-Item $TempMsiPath -Force -ErrorAction SilentlyContinue }
    Write-Log "Downloading MSI from $SourceUrl"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $TempMsiPath -UseBasicParsing
    Write-Log "Downloaded to temp file: $TempMsiPath"
} catch {
    Write-Log "Download error: $_"
    exit 1
}

# --- Ђтомарная замена с retry ---
$attempt = 0
$success = $false
while ($attempt -lt $MaxRetries -and -not $success) {
    $attempt++
    try {
        Move-Item -Path $TempMsiPath -Destination $MsiPath -Force -ErrorAction Stop
        $success = $true
        Write-Log "MSI replaced successfully (attempt $attempt)"
    } catch {
        Write-Log "Attempt $attempt failed: $_"
        if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelaySec }
    }
}

if (-not $success) {
    Write-Log "FAILED to replace MSI after $MaxRetries attempts"
    exit 1
}

Write-Log "Done."
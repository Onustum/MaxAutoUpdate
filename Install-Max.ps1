# --- Settings ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$MsiSourcePath   = "Folder\To\MAX.msi"
$MsiProductName  = "MAX"
$MaxProcessName  = "max"

# Лог — как было, в TEMP пользователя
$LogFile = Join-Path $env:TEMP "max_update.log"

# Основной путь, куда ставится per-user MAX
$MaxExePath = Join-Path $env:APPDATA "MAX\max.exe"
$TargetDir  = Join-Path $env:APPDATA "MAX"

# Дополнительные пути на случай, если установка ушла в другое место
$MaxExeFallbackPaths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\MAX\max.exe"),
    (Join-Path $env:LOCALAPPDATA "MAX\max.exe"),
    "C:\Program Files\MAX\max.exe",
    "C:\Program Files (x86)\MAX\max.exe"
)

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Add-Content -Path $LogFile -Value "$timestamp  $Message" -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Fallback, если основной лог недоступен
        try {
            $fallback = Join-Path $env:TEMP "max_update_fallback.log"
            Add-Content -Path $fallback -Value "$timestamp  $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Clean-Version {
    # Приводит версию к первым трём числам: 26.33.0.79506 -> 26.33.0
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $clean = ([string]$Raw -replace '[^0-9\.]', '')
    if (-not $clean) { return $null }
    $parts = $clean.Trim('.').Split('.')
    if ($parts.Count -ge 3) {
        return ($parts[0..2] -join '.')
    }
    return $clean.Trim('.')
}

function Get-InstalledMaxVersion {
    # Читаем версию прямо из exe-файла. Приоритет — %APPDATA%\MAX\max.exe.
    $paths = @($MaxExePath) + $MaxExeFallbackPaths
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                $verInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($p)
                $raw = $verInfo.FileVersion
                $clean = Clean-Version -Raw $raw
                Write-Log "Found MAX at $p, file version: '$raw' -> '$clean'"
                return $clean
            } catch {
                Write-Log "Failed to read version from $p : $_"
            }
        }
    }
    Write-Log "No MAX.exe found in any known path."
    return $null
}

function Get-MsiVersion {
    param([string]$Path)
    $installer = $null
    $db = $null
    $view = $null
    $record = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        $raw = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)
        return Clean-Version -Raw $raw
    } catch {
        Write-Log "Failed to read MSI version: $_"
        return $null
    } finally {
        # Освобождаем COM-объекты, чтобы не копить утечки
        foreach ($obj in @($record, $view, $db, $installer)) {
            if ($obj -ne $null) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch { }
            }
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

# --- Начало ---
Write-Log "=== MAX update script started ==="
Write-Log "User: $env:USERDOMAIN\$env:USERNAME  Computer: $env:COMPUTERNAME"
Write-Log "APPDATA=$env:APPDATA"
Write-Log "TARGETDIR=$TargetDir"

# --- Диагностика политик Installer (важно для per-user установки) ---
try {
    $dui     = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Name DisableUserInstalls   -ErrorAction SilentlyContinue).DisableUserInstalls
    $aieHklm = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated
    $aieHkcu = (Get-ItemProperty "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated
    Write-Log "Installer policies: DisableUserInstalls=$dui AlwaysInstallElevated(HKLM)=$aieHklm AlwaysInstallElevated(HKCU)=$aieHkcu"
} catch {
    Write-Log "Failed to read Installer policies: $_"
}

# --- Check MSI availability ---
if (-not (Test-Path $MsiSourcePath)) {
    Write-Log "MSI not found: $MsiSourcePath"
    exit 1
}

$installedVersion = Get-InstalledMaxVersion
$packageVersion   = Get-MsiVersion -Path $MsiSourcePath

Write-Log "Installed: [$installedVersion] | Package: [$packageVersion]"

# --- Compare versions ---
$needInstall = $true
if (-not $installedVersion) {
    Write-Log "Installed version not detected - proceeding with install."
} elseif (-not $packageVersion) {
    Write-Log "Package version not detected - proceeding with install."
} else {
    $instClean = Clean-Version -Raw $installedVersion
    $pkgClean  = Clean-Version -Raw $packageVersion

    Write-Log "Final compare: installed='$instClean' package='$pkgClean'"

    try {
        $vInst = [version]$instClean
        $vPkg  = [version]$pkgClean
        if ($vInst -ge $vPkg) {
            Write-Log "Installed version >= package version - no update required."
            $needInstall = $false
        } else {
            Write-Log "Package is newer - proceeding with install."
        }
    } catch {
        # Fallback: строковое сравнение
        if ($instClean -eq $pkgClean) {
            Write-Log "Versions match (string compare) - no update required."
            $needInstall = $false
        } else {
            Write-Log "Versions differ (string compare) - proceeding with install."
        }
    }
}

# --- Close MAX ---
$proc = Get-Process -Name $MaxProcessName -ErrorAction SilentlyContinue
if ($proc) {
    Write-Log "Closing MAX..."
    Stop-Process -Name $MaxProcessName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# --- Если установка не нужна — просто запускаем MAX и выходим ---
if (-not $needInstall) {
    $launched = $false
    foreach ($path in (@($MaxExePath) + $MaxExeFallbackPaths)) {
        if (Test-Path $path) {
            Start-Process -FilePath $path
            Write-Log "Launched (no install needed): $path"
            $launched = $true
            break
        }
    }
    if (-not $launched) {
        Write-Log "MAX.exe not found in any known path (no install needed)."
    }
    Write-Log "Done (no update)."
    exit 0
}

# --- Copy MSI to TEMP and install ---
# Уникальное имя файла — чтобы не конфликтовать при параллельных установках
$tempMsi = Join-Path $env:TEMP ("MAX_{0}.msi" -f [guid]::NewGuid().ToString("N"))
try {
    Copy-Item -Path $MsiSourcePath -Destination $tempMsi -Force -ErrorAction Stop
    Write-Log "MSI copied to $tempMsi"
} catch {
    Write-Log "Failed to copy MSI: $_"
    exit 1
}

Write-Log "Installing..."
# TARGETDIR передаём уже раскрытым через PowerShell
$argString = "/i `"$tempMsi`" ALLUSERS=2 MSIINSTALLPERUSER=1 /qn /norestart TARGETDIR=`"$TargetDir`""
Write-Log "msiexec args: $argString"

$p = Start-Process -FilePath "msiexec.exe" -ArgumentList $argString -Wait -PassThru
$code = $p.ExitCode
Write-Log "msiexec exit code: $code"

if ($code -in 0, 3010, 1641) {
    Write-Log "Install considered successful."
} else {
    Write-Log "Install FAILED with code $code"
}

Remove-Item -Path $tempMsi -Force -ErrorAction SilentlyContinue

# --- Launch MAX ---
$launched = $false
foreach ($path in (@($MaxExePath) + $MaxExeFallbackPaths)) {
    if (Test-Path $path) {
        Start-Process -FilePath $path
        Write-Log "Launched: $path"
        $launched = $true
        break
    }
}
if (-not $launched) {
    Write-Log "MAX.exe not found in any known path:"
    foreach ($path in (@($MaxExePath) + $MaxExeFallbackPaths)) { Write-Log "   checked: $path" }
}

Write-Log "Done."
exit 0
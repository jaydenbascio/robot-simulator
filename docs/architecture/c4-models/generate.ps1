[CmdletBinding()]
param (
    [string]$DslFileName = "workspace.dsl"
)

$ErrorActionPreference = "Stop"
Write-Host "[*] Starting C4 Static Site generation process..." -ForegroundColor Cyan

$OutputDirName = "static"

# 1. Environment and Path Validation
$DslPath = Join-Path $PSScriptRoot $DslFileName
$OutputPath = Join-Path $PSScriptRoot $OutputDirName

if (-not (Test-Path $DslPath)) {
    throw "Critical Error: '$DslFileName' not found at: $DslPath"
}

$CliExecutable = Get-Command "structurizr" -ErrorAction SilentlyContinue
if (-not $CliExecutable) {
    throw "Critical Error: Structurizr CLI ('structurizr') is not installed or missing from your system PATH."
}

# 2. Preparation of Output Directory
if (Test-Path $OutputPath) {
    Write-Host "[*] Cleaning existing output directory: $OutputPath" -ForegroundColor Yellow
    Remove-Item $OutputPath -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $OutputPath -Force

# 3. Execution of Structurizr CLI Local Export
Write-Host "[*] Executing Structurizr CLI local static export..." -ForegroundColor Cyan
$CliArgs = @("export", "-workspace", "`"$DslPath`"", "-format", "static", "-output", "`"$OutputPath`"")

try {
    # Run natively without spawning a separate cmd/powershell process wrapper
    $Process = Start-Process -FilePath $CliExecutable.Source -ArgumentList $CliArgs -NoNewWindow -PassThru -Wait
    
    if ($Process.ExitCode -ne 0) {
        throw "Structurizr CLI exited with non-zero code: $($Process.ExitCode)"
    }
    
    Write-Host "[+] Success! Static C4 model web assets generated at: $OutputPath" -ForegroundColor Green
    Write-Host "Open '$OutputPath\index.html' in your browser to view your diagrams." -ForegroundColor Gray
}
catch {
    Write-Error "Generation Failed: $_"
    exit 1
}

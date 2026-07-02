param(
    [string] $RepoRoot,
    [switch] $Uninstall,
    [switch] $ci
)

$ErrorActionPreference = 'Stop'

function Write-Banner { param([string] $Title)
    $bar = '=' * 55
    Write-Host $bar -ForegroundColor White; Write-Host $Title -ForegroundColor White; Write-Host $bar -ForegroundColor White
}
function Write-Info  { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Warn2 { param([string] $Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Step  { param([string] $Message) Write-Host "[*] $Message" -ForegroundColor Yellow }
function Write-Ok    { param([string] $Message) Write-Host "[+] $Message" -ForegroundColor Green }

function Fail { param([string] $Message)
    Write-Host ''; Write-Host "[X] $Message" -ForegroundColor Red
    if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 1
}

# Refresh this session's PATH via Chocolatey's own Update-SessionEnvironment (refreshenv) when available;
# falls back to a registry Machine+User merge before choco exists. See AGENTS.md.
function Update-SessionPath {
    if (-not $env:ChocolateyInstall) { $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey' }
    $profileModule = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    if (Test-Path $profileModule) {
        Import-Module $profileModule -ErrorAction SilentlyContinue
        # refreshenv emits non-terminating errors internally that our script-scope $ErrorActionPreference='Stop'
        # would escalate to a script-aborting throw (which was skipping the VS Code + build steps). Swallow any
        # failure and fall through to the registry merge below.
        if (Get-Command Update-SessionEnvironment -ErrorAction SilentlyContinue) {
            try { Update-SessionEnvironment; return } catch { }
        }
    }
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ } | ForEach-Object { $_ -split ';' } | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

# ======================================================================
# Main
# ======================================================================
# This script lives in <repo>\scripts\, so without -RepoRoot the repo root is one level up
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot   = (Resolve-Path $RepoRoot).Path
$ReadmePath = Join-Path $RepoRoot 'README.md'   # README is ALWAYS taken from the repo root

# packages.config either in root dir or in the cloned repo root's (prefer former)
$localPkg = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'packages.config' } else { $null }
$repoPkg  = Join-Path $RepoRoot 'packages.config'
if ($localPkg -and (Test-Path $localPkg) -and ($localPkg -ne $repoPkg)) { $PackagesFile = $localPkg; $usingLocalPkg = $true }
else { $PackagesFile = $repoPkg; $usingLocalPkg = $false }

$bannerTitle = if ($Uninstall) { 'Developer Machine Setup  -  Uninstall toolchain' } else { 'Developer Machine Setup  -  Step 2 of 2 (toolchain)' }
Write-Banner $bannerTitle
if ($Uninstall) { Write-Host '[MODE] Uninstall - packages listed in packages.config will be removed.' -ForegroundColor Magenta }

# 0. Elevate (Chocolatey needs Administrator)
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn2 'Administrator rights required. Relaunching elevated...'
    $argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$PSCommandPath`"",'-RepoRoot',"`"$RepoRoot`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($ci)    { $argList += '-ci' }
    try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -Wait }
    catch { Fail 'Elevation was declined. Re-run from an Administrator PowerShell.' }
    Stop-Process -Id $PID -Force
}

Update-SessionPath
if (-not (Test-Path $PackagesFile)) { Fail "Could not find packages.config at '$PackagesFile'." }

# ---- Uninstall mode: choco uninstall each id in packages.config, then exit ----
if ($Uninstall) {
    Write-Info 'Removing toolchain (from packages.config)'
    if ($usingLocalPkg) { Write-Warn2 "Using local packages.config next to setupc.ps1 (troubleshooting): $PackagesFile" }

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Warn2 'Chocolatey is not installed - nothing to uninstall.'
        if (-not $ci) {
            Write-Host ''; Write-Host 'Closing this window...' -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        exit 0
    }

    # Auto-confirm every choco prompt (e.g. the metapackage "uninstall X.install as well?" question, which -y does
    # NOT cover and which otherwise blocks for 20s). This is choco's native "always say yes" switch.
    choco feature enable -n allowGlobalConfirmation | Out-Null

    try { [xml]$pkgXml = Get-Content -Raw -Path $PackagesFile } catch { Fail "packages.config is not valid XML: $($_.Exception.Message)" }
    $ids = @($pkgXml.packages.package | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    if ($ids.Count -eq 0) { Fail 'packages.config lists no packages.' }

    # A leftover bare metapackage (e.g. cmake) from an older run DEPENDS ON its .install package and blocks its
    # removal ("Unable to uninstall cmake.install because cmake depends on it"). So uninstall those metapackage
    # siblings FIRST. Each iteration skips anything not currently in choco's lib folder - which also skips a .install
    # that the metapackage's auto-confirmed uninstall just cascaded away, so no "not installed" errors are produced.
    if (-not $env:ChocolateyInstall) { $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey' }
    $chocoLib  = Join-Path $env:ChocolateyInstall 'lib'
    $metaFirst = @($ids | Where-Object { $_ -match '\.install$' } | ForEach-Object { $_ -replace '\.install$','' })
    $order = @($metaFirst + $ids | Select-Object -Unique)

    $anyFail = $false
    foreach ($id in $order) {
        if (-not (Test-Path (Join-Path $chocoLib $id))) { continue }   # not installed (or already cascaded away)
        Write-Step "Uninstalling $id ..."
        choco uninstall $id --yes --force
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010 -and ($ids -contains $id)) { $anyFail = $true; Write-Warn2 "choco uninstall $id exited $LASTEXITCODE" }
    }

    Write-Info 'Summary'
    if ($anyFail) {
        Write-Host '[x] Some packages did not uninstall cleanly - see Chocolatey output above.' -ForegroundColor Red
        # Not error-free: hold the window open so the failures stay readable.
        if (-not $ci -and $Host.Name -eq 'ConsoleHost') { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
    }
    else {
        Write-Ok 'All toolchain packages removed (or were already absent).'
        if (-not $ci) { Write-Host ''; Write-Host 'Closing this window...' -ForegroundColor Green; Start-Sleep -Seconds 2 }
    }
    exit $(if ($anyFail) { 1 } else { 0 })
}

# ---- 1. Ensure Chocolatey ----
Write-Info 'Package manager'
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Ok "Chocolatey already installed  $(choco --version 2>&1 | Select-Object -First 1)"
}
else {
    Write-Step 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Update-SessionPath
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { Fail 'Chocolatey installation did not complete. Open a new Administrator PowerShell and re-run setupc.ps1.' }
    Write-Ok "Chocolatey installed  $(choco --version 2>&1 | Select-Object -First 1)"
}

# Auto-confirm every choco prompt (always say yes) so nothing blocks the unattended install below.
choco feature enable -n allowGlobalConfirmation | Out-Null

# ---- 2. Install the toolchain using ONE native packages.config install
Write-Info 'Toolchain (from packages.config)'
if ($usingLocalPkg) { Write-Warn2 "Using local packages.config next to setupc.ps1 (should be in root directory): $PackagesFile" }
choco install $PackagesFile --yes
$installExit = $LASTEXITCODE
$success = ($installExit -eq 0 -or $installExit -eq 3010)   # 3010 = success, reboot required
Update-SessionPath

# ---- 3. Summary ----
Write-Info 'Summary'
if ($success) { Write-Ok 'SUCCESS: Chocolatey installed all packages.' }
else {
    Write-Host "[x] FAILURE: choco install exited $installExit - see Chocolatey output above." -ForegroundColor Red
    Write-Host 'A reboot may be needed for PATH changes to take effect; re-run setupc.ps1 afterwards.' -ForegroundColor Yellow
}

# ---- 4. Open README in VS Code (unless -ci). Start-Process detaches so this shell returns to a prompt. ----
if (-not $ci) {
    if (Test-Path $ReadmePath) {
        $code = Get-Command code -ErrorAction SilentlyContinue
        if (-not $code) { $code = Get-Command code.cmd -ErrorAction SilentlyContinue }
        if ($code) {
            Write-Step 'Opening the project in VS Code...'

            # Start code.cmd in a hidden window
            try { Start-Process -FilePath $code.Source -ArgumentList $RepoRoot, $ReadmePath -WindowStyle Hidden }
            catch { Write-Warn2 "Could not launch VS Code ($($_.Exception.Message)). Open it manually: $ReadmePath" }
        }
        else { Write-Warn2 "VS Code was not found on PATH. Open it manually: $ReadmePath" }
    }
    else { Write-Warn2 "No README.md found at '$ReadmePath'." }
}

# ---- 5. Build only if the toolchain came up clean AND this checkout has a CMake preset ----
$buildOk = $true
$presetsFile = Join-Path $RepoRoot 'CMakePresets.json'
if ($success -and (Test-Path $presetsFile)) {
    Write-Info 'Building the project'

    # Resolve the debug preset's binaryDir from CMakePresets.json (fall back to <repo>\build).
    $buildDir = Join-Path $RepoRoot 'build'
    try {
        $cp = (Get-Content -Raw $presetsFile | ConvertFrom-Json).configurePresets | Where-Object { $_.name -eq 'debug' } | Select-Object -First 1
        if ($cp -and $cp.binaryDir) {
            $buildDir = [System.IO.Path]::GetFullPath(
                $cp.binaryDir.Replace('${sourceDir}', $RepoRoot).Replace('${presetName}', 'debug')
            )
        }
    } catch { }
    
    # Wipe the build directory first so a stale/corrupt CMake cache can't break the configure step
    if (Test-Path $buildDir) {
        Write-Step "Removing existing build folder (clean cache): $buildDir"
        try { Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction Stop }
        catch { Write-Warn2 "Could not fully remove '$buildDir': $($_.Exception.Message)" }
    }

    # Disable Smart App Control before building, so freshly-compiled (unsigned) binaries are allowed to run.
    Write-Step 'Disabling Smart App Control...'
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -Value 0 -ErrorAction Stop
        # CiTool -r prints "Press Enter to Continue" and blocks on stdin; pipe a newline to auto-answer it.
        '' | CiTool.exe -r
    }
    catch { Write-Warn2 "Could not disable Smart App Control: $($_.Exception.Message)" }

    # Try to run cmake
    Push-Location -LiteralPath $RepoRoot
    try {
        Write-Step 'cmake --preset debug'
        cmake --preset debug
        if ($LASTEXITCODE -eq 0) {
            Write-Step 'cmake --build --preset debug-build'
            cmake --build --preset debug-build
            $buildOk = ($LASTEXITCODE -eq 0)
        }
        else { $buildOk = $false; Write-Warn2 "cmake --preset debug failed (exit $LASTEXITCODE) - skipping build." }
    }
    finally { Pop-Location }
}

if ($ci) { exit $(if ($success -and $buildOk) { 0 } else { 1 }) }

# Interactive runs: only auto-close if error-free. On any issue, hold the window so the output stays readable.
Write-Host ''
if ($success -and $buildOk) {
    Write-Host 'Setup complete.' -ForegroundColor Green   # error-free: let this window close on its own
}
else {
    Write-Host 'Setup finished with issues - see above.' -ForegroundColor Yellow
    if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
}

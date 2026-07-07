param(
    [string] $RepoRoot,
    [switch] $Uninstall,
    [switch] $ci
)

$ErrorActionPreference = 'Stop'
# Write-Progress (used internally by Expand-Archive - e.g. the official Chocolatey bootstrap script, run via
# Invoke-Expression, unzipping chocolatey.zip) renders its own animated bar, independent of anything
# --quiet/--no-progress controls on git/choco/winget. It's silenced via $ProgressPreference - but this MUST be
# $global: Expand-Archive is an advanced function inside the Microsoft.PowerShell.Archive module, and a
# script-scope value doesn't reliably reach it across the IEX'd bootstrap's scope; global is in every scope
# chain. -ci must be fully animation-free; interactive keeps native feedback visible.
if ($ci) { $global:ProgressPreference = 'SilentlyContinue' }

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
    Show-ClosingFooter -Ok $false
    exit 1
}

# Pause on failure / brief close notice on success; never blocks in -ci.
function Show-ClosingFooter { param([bool] $Ok)
    if ($ci) { return }
    if ($Ok) { Write-Host ''; Write-Host 'Closing this window...' -ForegroundColor Green; Start-Sleep -Seconds 2 }
    elseif ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
}

# choco's own refreshenv when available; registry merge before choco exists (and always in -Uninstall - see
# below). The try/catch is REQUIRED: refreshenv emits non-terminating errors that our
# $ErrorActionPreference='Stop' would turn script-fatal.
function Update-SessionPath {
    if (-not $env:ChocolateyInstall) {
        # Prefer choco's own persisted install location (custom installs set this); ProgramData is just the default.
        $env:ChocolateyInstall = [Environment]::GetEnvironmentVariable('ChocolateyInstall','Machine')
        if (-not $env:ChocolateyInstall) { $env:ChocolateyInstall = Join-Path $env:ProgramData 'chocolatey' }
    }
    # -Uninstall deletes $env:ChocolateyInstall later in this SAME process. Importing chocolateyProfile.psm1
    # loads Chocolatey.PowerShell.dll into this process, and a loaded .NET assembly can't be unloaded without
    # unloading the whole process - so that later Remove-Item would fail with "Access ... is denied" on the DLL,
    # no matter how elevated we are. Skip the module entirely here; the plain merge below is enough to resolve
    # choco/git on PATH, which is all -Uninstall needs.
    if (-not $Uninstall) {
        Import-Module (Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1') -ErrorAction SilentlyContinue
        if (Get-Command Update-SessionEnvironment -ErrorAction SilentlyContinue) {
            try { Update-SessionEnvironment; return } catch { }
        }
    }
    $env:Path = @([Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User')) -join ';'
}

# Native choco config: auto-confirm every prompt (--yes does NOT cover the metapackage uninstall prompt)
# and no download-progress animation. Persistent global settings, deliberately.
function Set-ChocoDefaults {
    choco feature enable -n allowGlobalConfirmation | Out-Null
    choco feature disable -n showDownloadProgress | Out-Null
}

# ======================================================================
# Main
# ======================================================================
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }   # script lives in <repo>\scripts\
$RepoRoot   = (Resolve-Path $RepoRoot).Path
$ReadmePath = Join-Path $RepoRoot 'README.md'

# Prefer a packages.config next to this script (troubleshooting) over the repo root's.
$PackagesFile = Join-Path $RepoRoot 'packages.config'
$localPkg = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'packages.config' }
$usingLocalPkg = $localPkg -and ($localPkg -ne $PackagesFile) -and (Test-Path $localPkg)
if ($usingLocalPkg) { $PackagesFile = $localPkg }

Write-Banner $(if ($Uninstall) { 'Developer Machine Setup  -  Uninstall toolchain' } else { 'Developer Machine Setup  -  Step 2 of 2 (toolchain)' })
if ($Uninstall) { Write-Host '[MODE] Uninstall - packages listed in packages.config, and Chocolatey itself, will be removed.' -ForegroundColor Magenta }

# Elevate (Chocolatey needs Administrator)
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn2 'Administrator rights required. Relaunching elevated...'
    $argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$PSCommandPath`"",'-RepoRoot',"`"$RepoRoot`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($ci) { $argList += '-ci' }
    try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -Wait }
    catch { Fail 'Elevation was declined. Re-run from an Administrator PowerShell.' }
    Stop-Process -Id $PID -Force
}

Update-SessionPath
if (-not $Uninstall -and -not (Test-Path $PackagesFile)) { Fail "Could not find packages.config at '$PackagesFile'." }
if ($usingLocalPkg -and (Test-Path $PackagesFile)) { Write-Warn2 "Using local packages.config next to setupc.ps1 (troubleshooting): $PackagesFile" }

# ---- Uninstall mode: batched choco uninstalls of the packages.config ids, then Chocolatey itself, then exit.
#      Chocolatey removal ALWAYS runs, even if packages.config is missing/invalid or choco absent - it's what
#      uninstalls everything else, so nothing here may hard-`Fail` before that final step. ----
if ($Uninstall) {
    Write-Info 'Removing toolchain (from packages.config)'
    $anyFail = $false

    # VS Code may still be running (a non-ci install auto-launches it at the end), and its own chocolatey
    # uninstaller can't replace/delete files that are still in use - the uninstall would silently leave it
    # behind. Close it first; -ErrorAction SilentlyContinue makes this a no-op when it isn't running.
    Get-Process -Name Code -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { Write-Warn2 'Chocolatey is not installed - skipping package removal.' }
    elseif (-not (Test-Path $PackagesFile)) { $anyFail = $true; Write-Warn2 "Could not find packages.config at '$PackagesFile' - skipping package removal." }
    else {
        Set-ChocoDefaults
        $ids = $null
        try { $ids = @(([xml](Get-Content -Raw -Path $PackagesFile)).packages.package.id | Where-Object { $_ }) }
        catch { $anyFail = $true; Write-Warn2 "packages.config is not valid XML: $($_.Exception.Message) - skipping package removal." }

        if ($ids) {
            $chocoLib = Join-Path $env:ChocolateyInstall 'lib'

            # Leftover bare metapackages (e.g. cmake) depend on their .install sibling and block its removal:
            # one native --remove-dependencies call takes out both. A second call sweeps whatever remains.
            $metas = @($ids -replace '\.install$','' | Where-Object { $_ -notin $ids -and (Test-Path (Join-Path $chocoLib $_)) })
            if ($metas) {
                Write-Step "Uninstalling leftover metapackages (with dependencies): $($metas -join ', ')"
                choco uninstall $metas --remove-dependencies --yes --force --no-progress
                if ($LASTEXITCODE -notin 0,3010) { $anyFail = $true }
            }
            $rest = @($ids | Where-Object { Test-Path (Join-Path $chocoLib $_) })   # re-checked live: -x above may have cascaded some away
            if ($rest) {
                Write-Step "Uninstalling: $($rest -join ', ')"
                choco uninstall $rest --yes --force --no-progress
                if ($LASTEXITCODE -notin 0,3010) { $anyFail = $true }
            }
        }
        elseif ($null -ne $ids) { $anyFail = $true; Write-Warn2 'packages.config lists no packages - skipping package removal.' }
    }

    # Git installed by setup.ps1's winget bootstrap is invisible to choco (that's deliberate - see the
    # install-side "excluding git.install" note above), so choco uninstalling everything else never removes
    # it. Reverse the winget install explicitly. -ci: --silent (no installer GUI) + --disable-interactivity.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget list --id Git.Git --exact --source winget *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Step 'Uninstalling Git (winget)...'
            if ($ci) { winget uninstall --id Git.Git --exact --source winget --silent --disable-interactivity | Out-Null }
            else { winget uninstall --id Git.Git --exact --source winget }
            if ($LASTEXITCODE -ne 0) { $anyFail = $true; Write-Warn2 "winget uninstall Git.Git exited $LASTEXITCODE" }
        }
    }

    # Chocolatey ships no self-uninstall command; docs.chocolatey.org's manual removal is: delete the
    # install dir + HTTP cache, and strip its PATH entry/env vars so nothing dangling is left behind.
    Write-Info 'Removing Chocolatey'
    foreach ($dir in @($env:ChocolateyInstall, (Join-Path $env:ProgramData 'ChocolateyHttpCache'))) {
        if ($dir -and (Test-Path $dir)) {
            Write-Step "Removing $dir ..."
            try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop }
            catch { $anyFail = $true; Write-Warn2 "Could not fully remove '$dir': $($_.Exception.Message)" }
        }
    }
    foreach ($scope in 'Machine','User') {
        $p = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($p -match '(?i)\\chocolatey\\bin') {
            $clean = ($p -split ';' | Where-Object { $_ -and $_ -notmatch '(?i)\\chocolatey\\bin' }) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $clean, $scope)
        }
    }
    foreach ($var in 'ChocolateyInstall','ChocolateyLastPathUpdate','ChocolateyToolsLocation') {
        [Environment]::SetEnvironmentVariable($var, $null, 'Machine')
    }

    Write-Info 'Summary'
    if ($anyFail) { Write-Host '[x] Some packages or Chocolatey itself did not uninstall cleanly - see output above.' -ForegroundColor Red }
    else { Write-Ok 'All toolchain packages and Chocolatey itself were removed.' }
    Show-ClosingFooter -Ok (-not $anyFail)
    exit [int]$anyFail
}

# ---- 1. Ensure Chocolatey ----
Write-Info 'Package manager'
if (Get-Command choco -ErrorAction SilentlyContinue) { Write-Ok "Chocolatey already installed  $(choco --version)" }
else {
    Write-Step 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Update-SessionPath
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { Fail 'Chocolatey installation did not complete. Open a new Administrator PowerShell and re-run setupc.ps1.' }
    Write-Ok "Chocolatey installed  $(choco --version)"
}
Set-ChocoDefaults

# ---- 2. Install the toolchain: ONE native packages.config call, from a temp copy with excluded ids
#         stripped out first (everything else, incl. installArguments, passes through unchanged):
#           - vscode.install in -ci (no editor on an unattended box)
#           - git.install if Git is already on PATH but NOT choco-tracked (setup.ps1's winget install -
#             choco has no record of it, so it would silently reinstall/redownload over it otherwise)
Write-Info 'Toolchain (from packages.config)'
$exclude = @()
if ($ci) { $exclude += 'vscode.install' }
if ((Get-Command git -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $env:ChocolateyInstall 'lib\git.install'))) { $exclude += 'git.install' }

$InstallFile = $PackagesFile
if ($exclude) {
    [xml]$pkgXml = Get-Content -Raw -Path $PackagesFile
    foreach ($id in $exclude) {
        $pkgXml.packages.package | Where-Object { $_.id -eq $id } | ForEach-Object {
            Write-Warn2 "Excluding $id from the toolchain install (already installed outside choco)."
            [void]$pkgXml.packages.RemoveChild($_)
        }
    }
    $InstallFile = Join-Path $env:TEMP 'packages.filtered.config'
    $pkgXml.Save($InstallFile)
}
choco install $InstallFile --yes
$installExit = $LASTEXITCODE
$success = $installExit -in 0,3010   # 3010 = success, reboot required
Update-SessionPath

# ---- 3. Summary ----
Write-Info 'Summary'
if ($success) { Write-Ok 'SUCCESS: Chocolatey installed all packages.' }
else {
    Write-Host "[x] FAILURE: choco install exited $installExit - see Chocolatey output above." -ForegroundColor Red
    Write-Host 'A reboot may be needed for PATH changes to take effect; re-run setupc.ps1 afterwards.' -ForegroundColor Yellow
}

# ---- 4. Open README in VS Code (skipped in -ci). Detached, hidden window: no cmd box, and VS Code's
#         Electron startup logs land in that hidden console instead of this terminal. GUI opens normally. ----
if (-not $ci) {
    $code = Get-Command code, code.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not (Test-Path $ReadmePath)) { Write-Warn2 "No README.md found at '$ReadmePath'." }
    elseif (-not $code) { Write-Warn2 "VS Code was not found on PATH. Open it manually: $ReadmePath" }
    else {
        Write-Step 'Opening the project in VS Code...'
        try { Start-Process -FilePath $code.Source -ArgumentList $RepoRoot, $ReadmePath -WindowStyle Hidden }
        catch { Write-Warn2 "Could not launch VS Code ($($_.Exception.Message)). Open it manually: $ReadmePath" }
    }
}

# ---- 5. Build if the toolchain came up clean AND this checkout has CMake presets ----
$buildOk = $true
$presetsFile = Join-Path $RepoRoot 'CMakePresets.json'
if ($success -and (Test-Path $presetsFile)) {
    Write-Info 'Building the project'

    # Wipe the debug preset's binaryDir (fallback <repo>\build) so a stale CMake cache can't break configure.
    $buildDir = Join-Path $RepoRoot 'build'
    try {
        $cp = (Get-Content -Raw $presetsFile | ConvertFrom-Json).configurePresets | Where-Object name -eq 'debug' | Select-Object -First 1
        if ($cp.binaryDir) { $buildDir = [IO.Path]::GetFullPath($cp.binaryDir.Replace('${sourceDir}', $RepoRoot).Replace('${presetName}', 'debug')) }
    } catch { }
    if (Test-Path $buildDir) {
        Write-Step "Removing existing build folder (clean cache): $buildDir"
        try { Remove-Item -LiteralPath $buildDir -Recurse -Force } catch { Write-Warn2 "Could not fully remove '$buildDir': $($_.Exception.Message)" }
    }

    # Disable Smart App Control so freshly-compiled unsigned binaries can run.
    # The '' | is REQUIRED: CiTool -r blocks on a "Press Enter to Continue" stdin prompt.
    Write-Step 'Disabling Smart App Control...'
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -Value 0
        '' | CiTool.exe -r
    } catch { Write-Warn2 "Could not disable Smart App Control: $($_.Exception.Message)" }

    Push-Location -LiteralPath $RepoRoot
    try {
        Write-Step 'cmake --preset debug'
        cmake --preset debug
        if ($LASTEXITCODE -eq 0) {
            Write-Step 'cmake --build --preset debug-build'
            cmake --build --preset debug-build
            $buildOk = $LASTEXITCODE -eq 0
        }
        else { $buildOk = $false; Write-Warn2 "cmake --preset debug failed (exit $LASTEXITCODE) - skipping build." }
    }
    finally { Pop-Location }
}

if ($ci) { exit [int](-not ($success -and $buildOk)) }

Write-Host ''
if ($success -and $buildOk) { Write-Host 'Setup complete.' -ForegroundColor Green }
else { Write-Host 'Setup finished with issues - see above.' -ForegroundColor Yellow }
Show-ClosingFooter -Ok ($success -and $buildOk)

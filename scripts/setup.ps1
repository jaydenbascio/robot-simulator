param(
    [string] $ClonePath,
    [switch] $Uninstall,
    [switch] $ci
)

$ErrorActionPreference = 'Stop'
# Write-Progress (used internally by various cmdlets, incl. module advanced functions like Expand-Archive)
# renders its own animated bar independent of anything --quiet/--no-progress controls on git/winget. Silenced
# via $global:ProgressPreference - global (not script scope) so it reliably reaches module functions. -ci
# must be fully animation-free; interactive keeps native feedback visible.
if ($ci) { $global:ProgressPreference = 'SilentlyContinue' }

$RepositoryUrl  = 'https://github.com/jaydenbascio/robot-simulator'
$RepositoryName = [System.IO.Path]::GetFileNameWithoutExtension(($RepositoryUrl -split '/')[-1])
$script:HadIssue = $false   # any non-fatal warning; window only auto-closes when still false

function Write-Banner { param([string] $Title)
    $bar = '=' * 55
    Write-Host $bar -ForegroundColor White; Write-Host $Title -ForegroundColor White; Write-Host $bar -ForegroundColor White
}
function Write-Info { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Warn { param([string] $Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Step { param([string] $Message) Write-Host "[*] $Message" -ForegroundColor Yellow }
function Write-Ok   { param([string] $Message) Write-Host "[+] $Message" -ForegroundColor Green }

function Fail { param([string] $Message)
    Write-Host ''; Write-Host "[X] $Message" -ForegroundColor Red
    Show-ClosingFooter -Ok $false
    exit 1
}

# Pause on failure so output stays readable; never blocks in -ci.
function Show-ClosingFooter { param([bool] $Ok)
    if (-not $Ok -and -not $ci -and $Host.Name -eq 'ConsoleHost') {
        Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host)
    }
}

function Add-ForwardedSwitches { param([string[]] $ArgList)
    if ($Uninstall) { $ArgList += '-Uninstall' }
    if ($ci) { $ArgList += '-ci' }
    $ArgList
}

# Machine+User PATH merge (choco doesn't exist yet); Git's default dir appended for a just-installed Git.
function Update-SessionPath {
    $env:Path = @([Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User'), (Join-Path $env:ProgramFiles 'Git\cmd')) -join ';'
}

# A folder matches iff its .git\config origin URL matches $RepositoryUrl (regex read - no git.exe needed yet).
function Test-IsMatchingClone { param([string] $Path)
    $config = Get-Content -Raw -Path (Join-Path $Path '.git\config') -ErrorAction SilentlyContinue
    if ($config -match '\[remote\s+"origin"\][^\[]*?\burl\s*=\s*(\S+)') {
        ($Matches[1].TrimEnd('/') -replace '\.git$','') -eq $RepositoryUrl
    } else { $false }
}

# -Narrow (ci): script dir + Documents only. Broad (interactive/uninstall): cwd + common dev folders too.
function Find-ExistingClone { param([switch] $Narrow)
    $roots = if ($Narrow) { @($PSScriptRoot, [Environment]::GetFolderPath('MyDocuments')) }
             else {
                 @($PWD.Path, $PSScriptRoot, [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop')) +
                 ('Downloads','source\repos','Projects','Code','dev','git' | ForEach-Object { Join-Path $env:USERPROFILE $_ })
             }
    $candidates = foreach ($r in ($roots | Where-Object { $_ })) { $r; Join-Path $r $RepositoryName }
    foreach ($c in ($candidates | Select-Object -Unique)) {
        if ((Test-Path $c) -and (Test-IsMatchingClone $c)) { return $c }
    }
}

# WinForms folder picker (console host is STA since PS 3.0). Fails setup if cancelled.
function Select-CloneFolder { param([string] $Initial)
    Write-Warn 'Opening folder picker...'
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Select the folder to clone the repository into'; SelectedPath = $Initial; ShowNewFolderButton = $true }
    if ($d.ShowDialog() -ne 'OK') { Fail 'No folder was selected. Setup cancelled.' }
    $d.SelectedPath
}

function Read-YesNo { param([string] $Prompt)
    do { $a = (Read-Host $Prompt).Trim().ToUpper() } while ($a -notin 'Y','N')
    $a -eq 'Y'
}

# ======================================================================
# Main
# ======================================================================
Write-Banner 'Developer Machine Setup  -  Step 1 of 2 (bootstrap)'
if ($Uninstall) { Write-Host '[MODE] Uninstall - this run will remove the toolchain, not install it.' -ForegroundColor Magenta }

# Elevate FIRST so the whole chain runs under one UAC prompt.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn 'Administrator rights required. Relaunching elevated before any checks run...'
    $elevateArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$PSCommandPath`"")
    if ($ClonePath) { $elevateArgs += @('-ClonePath',"`"$ClonePath`"") }
    try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList (Add-ForwardedSwitches $elevateArgs) -Wait }
    catch { Fail 'Elevation was declined. Re-run from an Administrator PowerShell.' }
    Stop-Process -Id $PID -Force   # plain exit leaves -NoExit hosts alive
}

Update-SessionPath   # fresh PATH before any "already installed" checks

$defaultParent = [Environment]::GetFolderPath('MyDocuments')
$targetDir = $null

if ($Uninstall) {
    # Locate only - no prompts, no clone, no Git install. A setupc.ps1 next to this script also suffices.
    Write-Info 'Repository location (uninstall - no prompts, no clone)'
    if ($ClonePath -and (Test-Path (Join-Path $ClonePath "$RepositoryName\.git"))) { $targetDir = Join-Path $ClonePath $RepositoryName }
    if (-not $targetDir) { $targetDir = Find-ExistingClone }
    if (-not $targetDir -and $PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'setupc.ps1'))) { $targetDir = $PSScriptRoot }
    if (-not $targetDir) { Fail 'Uninstall needs an existing local clone, or a setupc.ps1 (and packages.config) next to setup.ps1 for troubleshooting. Neither was found.' }
    Write-Ok "Using $targetDir"
}
else {
    Write-Info 'Repository location'
    if ($ClonePath) { $parentDir = $ClonePath }
    elseif ($ci) {
        $targetDir = Find-ExistingClone -Narrow
        if ($targetDir) { Write-Ok "Found existing clone: $targetDir" }
        else { $parentDir = $defaultParent; Write-Ok "No existing clone found; creating in: $defaultParent" }
    }
    else {
        $existing = Find-ExistingClone
        if ($existing) {
            Write-Ok "Found existing clone: $existing"
            Write-Host ''; Write-Host 'An existing local clone of this repository was found at:' -ForegroundColor White; Write-Host $existing -ForegroundColor Yellow; Write-Host ''
            Write-Host '[Y] Yes, use this clone      [N] No, choose a different folder' -ForegroundColor White; Write-Host ''
            if (Read-YesNo 'Type Y to use it or N to choose a folder') { $targetDir = $existing }
            else { $parentDir = Select-CloneFolder $defaultParent }   # N -> folder picker directly, no re-prompt
        }
        else {
            Write-Host ''; Write-Host 'The repository will be cloned into:' -ForegroundColor White; Write-Host "$defaultParent\$RepositoryName" -ForegroundColor Yellow; Write-Host ''
            Write-Host '[Y] Yes, continue here       [N] No, let me choose a different folder' -ForegroundColor White; Write-Host ''
            if (Read-YesNo 'Type Y to continue or N to choose a folder') { $parentDir = $defaultParent }
            else { $parentDir = Select-CloneFolder $defaultParent }
        }
    }
    if (-not $targetDir) { $targetDir = Join-Path $parentDir $RepositoryName }

    # Git via winget (choco doesn't exist yet); --accept flags keep it unattended. Interactive runs leave the
    # installer UI/progress visible on purpose. -ci adds --silent (no installer GUI at all - nothing here
    # should ever show a window in -ci) and --disable-interactivity, and pipes output away (also drops
    # winget's own progress animation, same console-detection trick as git's --quiet).
    Write-Info 'Version control'
    if (Get-Command git -ErrorAction SilentlyContinue) { Write-Ok "Git already installed  $(git --version)" }
    else {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Fail 'winget is not available. Install "App Installer" from the Microsoft Store (or Git from https://git-scm.com) and re-run.' }
        Write-Step 'Installing Git via winget...'
        if ($ci) { winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements --silent --disable-interactivity | Out-Null }
        else { winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements }
        Update-SessionPath
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'Git was installed but is not on PATH. Close this window, open a NEW PowerShell, and re-run setup.ps1.' }
        Write-Ok "Git installed  $(git --version)"
    }

    # Clone (--quiet: no progress animation, errors still print)
    Write-Info 'Clone'
    if (Test-Path (Join-Path $targetDir '.git')) {
        Write-Ok 'Repository already cloned (reusing)'
        Write-Step 'Syncing submodules...'
        git -C $targetDir submodule update --init --recursive --quiet
        if ($LASTEXITCODE -ne 0) { $script:HadIssue = $true; Write-Warn "git submodule update failed (exit $LASTEXITCODE) - submodules may be missing." }
    }
    elseif (Test-Path $targetDir) { Fail "The folder '$targetDir' already exists and is not a Git repository. Move or remove it, then re-run setup.ps1." }
    else {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Write-Step "Cloning $RepositoryUrl ..."
        git clone --quiet --recurse-submodules $RepositoryUrl $targetDir
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $targetDir '.git'))) { Fail 'git clone failed. Check the repository URL and your network connection.' }
        Write-Ok 'Repository cloned'
    }
}

# Hand off to setupc.ps1 (prefer one next to THIS script - troubleshooting), then close.
Write-Info 'Handing off to the project installer...'
$repoSetup  = Join-Path $targetDir 'scripts\setupc.ps1'
$localSetup = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'setupc.ps1' }
if ($localSetup -and (Test-Path $localSetup)) { $repoSetup = $localSetup; Write-Warn "Using local setupc.ps1 next to setup.ps1 (troubleshooting): $repoSetup" }
elseif (-not (Test-Path $repoSetup)) { Fail "Could not find setupc.ps1 next to setup.ps1 or in the repository's scripts folder at '$repoSetup'." }

$argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$repoSetup`"",'-RepoRoot',"`"$targetDir`"")
Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (Add-ForwardedSwitches $argList)

if ($script:HadIssue) {
    Write-Warn 'Installer launched in a new window, but this bootstrap finished with warnings (see above).'
    Show-ClosingFooter -Ok $false
}
else {
    Write-Ok 'Installer launched in a new window. Closing this one.'
    Start-Sleep -Milliseconds 800
    Stop-Process -Id $PID -Force   # plain exit leaves -NoExit hosts alive
}

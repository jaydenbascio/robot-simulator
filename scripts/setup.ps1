param(
    [string] $ClonePath,
    [switch] $Uninstall,
    [switch] $ci
)

$ErrorActionPreference = 'Stop'

$RepositoryUrl  = 'https://github.com/jaydenbascio/robot-simulator'
$RepositoryName = [System.IO.Path]::GetFileNameWithoutExtension(($RepositoryUrl -split '/')[-1])

# Set by any non-fatal warning
# Script will only exit cleanly if this is still false
$script:HadIssue = $false

# Write a title (55 = at top, 55 at bottom, text in middle)
function Write-Banner { param([string] $Title)
    $bar = '=' * 55
    Write-Host $bar -ForegroundColor White; Write-Host $Title -ForegroundColor White; Write-Host $bar -ForegroundColor White
}

# Functions for writing status messages
function Write-Info  { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Warn { param([string] $Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Step  { param([string] $Message) Write-Host "[*] $Message" -ForegroundColor Yellow }
function Write-Ok    { param([string] $Message) Write-Host "[+] $Message" -ForegroundColor Green }

# Display error message and exit application
function Fail { param([string] $Message)
    Write-Host '';
    Write-Host "[X] $Message" -ForegroundColor Red
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host '';
        Write-Host 'Press Enter to close...' -ForegroundColor DarkGray;
        [void](Read-Host)
    }

    exit 1
}

# Get the version of a tool (and if it exists) given a list of possible commands
function Get-ToolVersion {
    param([string[]] $Commands, [string] $VersionArg = '--version')
    foreach ($c in $Commands) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) {
            $ver = 'installed'

            # Get version if possible
            try {
                $out = & $cmd.Source $VersionArg 2>&1 | Select-Object -First 1;
                if ($out) {
                    $ver = ([string]$out).Trim()
                }
            } catch { }
            
            return [pscustomobject]@{ Found = $true; Version = $ver; Path = $cmd.Source }
        }
    }
    
    # Aw man, we didn't find a command that worked!
    return [pscustomobject]@{ Found = $false; Version = $null; Path = $null }
}

# Refresh PATH environment variable
function Update-SessionPath {
    # Get PATH environment variable from the system
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    
    # Git has likely not been added yet (if we just installed it)
    $extra = @( (Join-Path $env:ProgramFiles 'Git\cmd') )
    
    # Extract all entries in PATH
    $parts = @($machinePath, $userPath) + $extra |
        Where-Object { $_ } |                     # Filter out empty or null entries
        ForEach-Object { $_ -split ';' } |        # Split by semicolon (;)
        Where-Object { $_ -and (Test-Path $_) } | # Filter out invalid paths
        Select-Object -Unique                     # Filter out duplicates

    # Set current PATH environment variable to system-wide PATH
    $env:Path = ($parts -join ';')
}

# ===== Clone-location discovery =====

# Convert github URLs to a standard format (https://github.com/user/repo)
function Get-NormalizedRepoUrl { param([string] $Url)
    if (-not $Url) { return '' }
    ($Url.Trim().TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
}

# Read origin URL from .git\config file
function Get-OriginUrlFromGitConfig { param([string] $Path)
    $configPath = Join-Path $Path '.git\config'
    if (-not (Test-Path $configPath)) { return $null }

    $content = Get-Content -Raw -Path $configPath -ErrorAction SilentlyContinue
    if (-not $content) { return $null }

    # Find and read url of block that looks something like this:
    # ```
    # .... (Other stuff) ...
    # [remote "origin"]
    #         url = https://github.com/user/repo
    # .... (More stuff)  ...
    # ```
    $m = [regex]::Match($content, '\[remote\s+"origin"\][^\[]*?\burl\s*=\s*(\S+)', 'IgnoreCase, Singleline')
    if ($m.Success) {
        return $m.Groups[1].Value.Trim()
    }

    return $null
}

# A folder matches $RepositoryUrl iff its origin remote matches
function Test-IsMatchingClone { param([string] $Path)
    $origin = Get-OriginUrlFromGitConfig -Path $Path
    if (-not $origin) {
        return $false
    }
    (Get-NormalizedRepoUrl $origin) -eq (Get-NormalizedRepoUrl $RepositoryUrl)
}

# Broad search (interactive/uninstall): cwd, script dir, and common user dev folders.
function Find-ExistingClone {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($PWD.Path) { $candidates.Add($PWD.Path); $candidates.Add((Join-Path $PWD.Path $RepositoryName)) }
    if ($PSScriptRoot -and $PSScriptRoot -ne $PWD.Path) { $candidates.Add($PSScriptRoot); $candidates.Add((Join-Path $PSScriptRoot $RepositoryName)) }
    $userDataRoots = @(
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'source\repos'),
        (Join-Path $env:USERPROFILE 'Projects'), (Join-Path $env:USERPROFILE 'Code'),
        (Join-Path $env:USERPROFILE 'dev'), (Join-Path $env:USERPROFILE 'git')
    )
    foreach ($root in $userDataRoots) { if ($root) { $candidates.Add((Join-Path $root $RepositoryName)) } }
    $seen = @{}
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $full = try { [System.IO.Path]::GetFullPath($c) } catch { continue }
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        if ((Test-Path $full) -and (Test-IsMatchingClone $full)) { return $full }
    }
    return $null
}

function Select-FolderDialog { param([string] $InitialPath, [string] $Description)
    $worker = {
        param($init, $desc)
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $desc; $dialog.SelectedPath = $init; $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { return (& $worker $InitialPath $Description) }
    $ps = [PowerShell]::Create(); $ps.Runspace = [RunspaceFactory]::CreateRunspace()
    $ps.Runspace.ApartmentState = 'STA'; $ps.Runspace.Open()
    [void]$ps.AddScript($worker).AddArgument($InitialPath).AddArgument($Description)
    $result = $ps.Invoke() | Select-Object -First 1
    $ps.Runspace.Close(); $ps.Dispose(); return $result
}

# Opens the folder picker; fails setup if the user cancels. Returns the chosen parent folder.
function Select-CloneFolder { param([string] $Initial)
    Write-Warn 'Opening folder picker...'
    $picked = Select-FolderDialog -InitialPath $Initial -Description 'Select the folder to clone the repository into'
    if (-not $picked) { Fail 'No folder was selected. Setup cancelled.' }
    return $picked
}

# ======================================================================
# Main
# ======================================================================
Write-Banner 'Developer Machine Setup  -  Step 1 of 2 (bootstrap)'
if ($Uninstall) { Write-Host '[MODE] Uninstall - this run will remove the toolchain, not install it.' -ForegroundColor Magenta }

# 0. Elevate FIRST (Git/choco installers need admin) so the whole chain runs under one UAC prompt.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn 'Administrator rights required. Relaunching elevated before any checks run...'
    $elevateArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$PSCommandPath`"")
    if ($ClonePath) { $elevateArgs += @('-ClonePath', "`"$ClonePath`"") }
    if ($Uninstall) { $elevateArgs += '-Uninstall' }
    if ($ci)    { $elevateArgs += '-ci' }
    try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $elevateArgs -Wait }
    catch { Fail 'Elevation was declined. Re-run from an Administrator PowerShell.' }
    # Force-close the original pre-elevation window (plain exit leaves -NoExit hosts alive).
    Stop-Process -Id $PID -Force
}

# Fresh PATH before any "is it already installed" checks (avoid false "missing" from a stale inherited PATH).
Update-SessionPath

$defaultParent = [Environment]::GetFolderPath('MyDocuments')
$targetDir = $null

if ($Uninstall) {
    # Uninstall never clones/installs Git; just silently locate where to run setupc.ps1 -Uninstall from.
    Write-Info 'Repository location (uninstall - no prompts, no clone)'
    if ($ClonePath -and (Test-Path (Join-Path (Join-Path $ClonePath $RepositoryName) '.git'))) { $targetDir = Join-Path $ClonePath $RepositoryName }
    if (-not $targetDir) { $existing = Find-ExistingClone; if ($existing) { $targetDir = $existing } }
    # A local setupc.ps1 (+ packages.config) next to this script is enough to uninstall - no real checkout required.
    if (-not $targetDir -and $PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'setupc.ps1'))) { $targetDir = $PSScriptRoot }
    if (-not $targetDir) { Fail 'Uninstall needs an existing local clone, or a setupc.ps1 (and packages.config) next to setup.ps1 for troubleshooting. Neither was found.' }
    Write-Ok "Using $targetDir"
}
else {
    Write-Info 'Repository location'
    if ($ci) {
        # Narrow, no-prompt: script dir then Documents; else silently clone into Documents. See Find-ExistingCloneForCI.
        if ($ClonePath) { $parentDir = $ClonePath }
        else {
            $existing = Find-ExistingCloneForCI
            if ($existing) { $targetDir = $existing; Write-Ok "Found existing clone: $existing" }
            else { $parentDir = $defaultParent; Write-Ok "No existing clone found; creating in: $defaultParent" }
        }
    }
    elseif ($ClonePath) { $parentDir = $ClonePath }
    else {
        $existing = Find-ExistingClone
        if ($existing) {
            Write-Ok "Found existing clone: $existing"
            Write-Host ''; Write-Host "An existing local clone of this repository was found at:" -ForegroundColor White; Write-Host $existing -ForegroundColor Yellow; Write-Host ''
            Write-Host "[Y] Yes, use this clone      [N] No, choose a different folder" -ForegroundColor White; Write-Host ''
            do { $answer = (Read-Host 'Type Y to use it or N to choose a folder').Trim().ToUpper() } while ($answer -notin @('Y','N'))
            if ($answer -eq 'Y') { $targetDir = $existing } else { $parentDir = Select-CloneFolder $defaultParent }   # N -> pick a folder directly (no re-prompt)
        }
        else {
            Write-Host ''; Write-Host "The repository will be cloned into:" -ForegroundColor White; Write-Host "$defaultParent\$RepositoryName" -ForegroundColor Yellow; Write-Host ''
            Write-Host "[Y] Yes, continue here       [N] No, let me choose a different folder" -ForegroundColor White; Write-Host ''
            do { $answer = (Read-Host 'Type Y to continue or N to choose a folder').Trim().ToUpper() } while ($answer -notin @('Y','N'))
            if ($answer -eq 'Y') { $parentDir = $defaultParent } else { $parentDir = Select-CloneFolder $defaultParent }
        }
    }

    if (-not $targetDir) { $targetDir = Join-Path $parentDir $RepositoryName }

    # 2. Git (needed to clone; installed via winget since choco doesn't exist yet). The --accept flags keep it
    #    fully automated; the installer UI is left visible (no --silent).
    Write-Info 'Version control'
    $git = Get-ToolVersion -Commands @('git')
    if ($git.Found) { Write-Ok "Git already installed  $($git.Version)" }
    else {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fail 'winget is not available. Install "App Installer" from the Microsoft Store (or Git from https://git-scm.com) and re-run.'
        }
        Write-Step 'Installing Git via winget...'
        winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements
        Update-SessionPath
        $git = Get-ToolVersion -Commands @('git')
        if (-not $git.Found) { Fail 'Git was installed but is not on PATH. Close this window, open a NEW PowerShell, and re-run setup.ps1.' }
        Write-Ok "Git installed  $($git.Version)"
    }

    # 3. Clone (native git progress printed straight to the console)
    Write-Info 'Clone'
    if (Test-Path $targetDir) {
        if (Test-Path (Join-Path $targetDir '.git')) {
            Write-Ok 'Repository already cloned (reusing)'
            # Init submodules missing from an older clone (predating --recurse-submodules, e.g. vcpkg).
            Write-Step 'Syncing submodules...'
            git -C $targetDir submodule update --init --recursive
            if ($LASTEXITCODE -ne 0) { $script:HadIssue = $true; Write-Warn "git submodule update failed (exit $LASTEXITCODE) - submodules may be missing." }
        }
        else { Fail "The folder '$targetDir' already exists and is not a Git repository. Move or remove it, then re-run setup.ps1." }
    }
    else {
        if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
        Write-Step "Cloning $RepositoryUrl ..."
        git clone --recurse-submodules --progress $RepositoryUrl $targetDir
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $targetDir '.git'))) { Fail 'git clone failed. Check the repository URL and your network connection.' }
        Write-Ok 'Repository cloned'
    }
}

# 4. Hand off to setupc.ps1, then close. Prefer a local setupc.ps1 next to THIS script (troubleshooting) over the repo's.
Write-Info 'Handing off to the project installer...'
$localSetup = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'setupc.ps1' } else { $null }
$repoSetupc = Join-Path $targetDir 'scripts\setupc.ps1'
if ($localSetup -and (Test-Path $localSetup)) { $repoSetup = $localSetup; Write-Warn "Using local setupc.ps1 next to setup.ps1 (troubleshooting): $repoSetup" }
elseif (Test-Path $repoSetupc) { $repoSetup = $repoSetupc }
else { Fail "Could not find setupc.ps1 next to setup.ps1 or in the repository's scripts folder at '$repoSetupc'." }

$hostExe = (Get-Process -Id $PID).Path
$argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$repoSetup`"",'-RepoRoot',"`"$targetDir`"")
if ($Uninstall) { $argList += '-Uninstall' }
if ($ci)    { $argList += '-ci' }
Start-Process -FilePath $hostExe -ArgumentList $argList

# Only auto-close this window if the run was error-free; otherwise hold it so the warnings stay readable.
if ($script:HadIssue) {
    Write-Warn 'Installer launched in a new window, but this bootstrap finished with warnings (see above).'
    if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
}
else {
    Write-Ok 'Installer launched in a new window. Closing this one.'
    # Force-close (plain exit leaves -NoExit hosts alive).
    Start-Sleep -Milliseconds 800
    Stop-Process -Id $PID -Force
}

<#
.SYNOPSIS
    Bootstrap setup script (setup.ps1) - Step 1 of 2.

.DESCRIPTION
    Downloaded and run on its own (lives OUTSIDE the repository). It:

        1. Ensures Git is installed (via winget) with a staged status UI:
           checking -> installing -> verifying -> installed vX.
        2. Asks where to clone (defaults to the Documents folder); N opens a
           folder picker.
        3. Clones https://github.com/jaydenbascio/robot-simulator, then launches
           the repo's setupc.ps1 in a new window and closes this one.

.PARAMETER Debug
    Verbose troubleshooting mode: full paths/variables printed, installers run
    visibly, raw command output shown instead of the spinner. Passed through to
    setupc.ps1.

.PARAMETER Uninstall
    Passed through to setupc.ps1: uninstalls the toolchain instead of
    installing it. Skips the directory prompts and the Git install entirely -
    there's nothing to clone into and no installer should run just to remove
    software. Silently locates an existing local clone (or a setupc.ps1
    placed next to this script for troubleshooting) and hands off from there.

.PARAMETER CI
    Fully unattended mode: no interactive prompts anywhere. Directory
    selection uses the same logic as normal, just without asking - it looks
    for an existing local clone (current/script directory, then common dev
    folders including Documents), and if nothing is found, silently defaults
    to the Documents folder with no confirmation. Passed through to
    setupc.ps1, where it also skips opening the README/VS Code.

.NOTES
        powershell -ExecutionPolicy Bypass -File .\setup.ps1
        powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Debug
        powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Uninstall
        powershell -ExecutionPolicy Bypass -File .\setup.ps1 -CI
#>

# NOTE: no [CmdletBinding()] on purpose, so -Debug binds to our own switch.
# PowerShell parameter binding is already case-insensitive, so -uninstall,
# -UNINSTALL, -Uninstall etc. all bind here identically.
param(
    [string] $ClonePath,
    [switch] $Debug,
    [switch] $Uninstall,
    [switch] $CI
)

$ErrorActionPreference = 'Stop'

$RepositoryUrl  = 'https://github.com/jaydenbascio/robot-simulator'
$RepositoryName = [System.IO.Path]::GetFileNameWithoutExtension(($RepositoryUrl -split '/')[-1])

# ======================================================================
# UI / status helpers.
# NOTE: this block is intentionally duplicated in setupc.ps1 so each script
# is self-contained. Keep the two copies in sync.
# ======================================================================
$script:DebugMode = [bool]$Debug

# ASCII-only glyphs. Avoid Unicode/braille spinners here: they render as
# garbled boxes/question marks on many Windows consoles (cmd.exe default
# codepage, redirected output, non-UTF8 terminals), so we keep this simple
# and portable everywhere instead of trying to detect encoding support.
$script:Spin = @('|','/','-','\')
$script:G    = @{ ok = '+'; fail = 'x'; work = '*' }

function Write-Banner {
    param([string] $Title)
    $bar = '=' * 55
    Write-Host $bar -ForegroundColor White
    Write-Host $Title -ForegroundColor White
    Write-Host $bar -ForegroundColor White
    if ($script:DebugMode) { Write-Host '[DEBUG] verbose output + visible installers' -ForegroundColor Magenta }
}

function Write-Debug2 { param([string] $Message) if ($script:DebugMode) { Write-Host "[debug] $Message" -ForegroundColor DarkGray } }
function Write-Info   { param([string] $Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Warn2  { param([string] $Message) Write-Host "[!] $Message" -ForegroundColor Yellow }

function Fail {
    param([string] $Message)
    Write-Host ''
    Write-Host "[X] $Message" -ForegroundColor Red
    if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Write-Host 'Press Enter to close...' -ForegroundColor DarkGray; [void](Read-Host) }
    exit 1
}

function Write-StatusLine {
    param(
        [string] $Component,
        [string] $Status,
        [ValidateSet('work','ok','fail')] [string] $Kind = 'work',
        [string] $Frame,
        [switch] $Final
    )
    $icon  = switch ($Kind) { 'ok' { $script:G.ok } 'fail' { $script:G.fail } default { if ($Frame) { $Frame } else { $script:G.work } } }
    $color = switch ($Kind) { 'ok' { 'Green' }      'fail' { 'Red' }        default { 'Yellow' } }
    $text  = "[$icon] " + $Component.PadRight(13) + " $Status"

    if ($script:DebugMode) {
        if ($PSBoundParameters.ContainsKey('Frame')) { return }
        Write-Host $text -ForegroundColor $color
        return
    }

    $width = try { [Console]::WindowWidth - 1 } catch { 100 }
    if ($width -lt 20) { $width = 100 }
    if ($text.Length -gt $width) { $text = $text.Substring(0, $width) } else { $text = $text.PadRight($width) }
    Write-Host ("`r" + $text) -NoNewline -ForegroundColor $color
    if ($Final) { Write-Host '' }
}

function Quote-Arg { param([string] $Value) if ($Value -match '[\s"]') { '"' + ($Value -replace '"', '\"') + '"' } else { $Value } }

function Invoke-Managed {
    param(
        [string]      $FilePath,
        [string[]]    $ArgumentList,
        [string]      $Component,
        [string]      $Status = 'installing...',
        [scriptblock] $Detailer,
        [switch]      $Visible
    )
    Write-Debug2 ("exec: {0} {1}" -f $FilePath, ($ArgumentList -join ' '))

    if ($script:DebugMode -or $Visible) {
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -Wait
        return $p.ExitCode
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $FilePath
    $psi.Arguments = (($ArgumentList | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $queue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $handler = { if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } }
    $r1 = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $handler -MessageData $queue
    $r2 = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $handler -MessageData $queue

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $frame  = 0
    $detail = $Status
    $line   = $null

    # Note: deliberately NOT using Write-Progress here - on this console host
    # it repaints/flashes the whole screen on every update instead of
    # rendering a stable bar, which is worse than no progress bar at all.
    # The spinner + text status line below is the actual progress indicator.
    while (-not $proc.HasExited) {
        while ($queue.TryDequeue([ref]$line)) { if ($Detailer) { $d = & $Detailer $line; if ($d) { $detail = $d } } }
        Write-StatusLine -Component $Component -Status $detail -Frame $script:Spin[$frame % $script:Spin.Count]
        $frame++
        Start-Sleep -Milliseconds 110
    }
    while ($queue.TryDequeue([ref]$line)) { if ($Detailer) { $d = & $Detailer $line; if ($d) { $detail = $d } } }

    Unregister-Event -SourceIdentifier $r1.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $r2.Name -ErrorAction SilentlyContinue
    Remove-Job -Job $r1 -Force -ErrorAction SilentlyContinue
    Remove-Job -Job $r2 -Force -ErrorAction SilentlyContinue

    return $proc.ExitCode
}

function Get-ToolVersion {
    param([string[]] $Commands, [string] $VersionArg = '--version')
    foreach ($c in $Commands) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) {
            $ver = 'installed'
            try { $out = & $cmd.Source $VersionArg 2>&1 | Select-Object -First 1; if ($out) { $ver = ([string]$out).Trim() } } catch { }
            return [pscustomobject]@{ Found = $true; Version = $ver; Path = $cmd.Source }
        }
    }
    return [pscustomobject]@{ Found = $false; Version = $null; Path = $null }
}

function Update-SessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = @( (Join-Path $env:ProgramFiles 'Git\cmd'), (Join-Path $env:ProgramData 'chocolatey\bin') )
    $parts = @($machinePath, $userPath) + $extra |
        Where-Object { $_ } | ForEach-Object { $_ -split ';' } |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $env:Path = ($parts -join ';')
    Write-Debug2 "PATH refreshed ($($parts.Count) entries)"
}

# ======================================================================
# Main
# ======================================================================
Write-Banner 'Developer Machine Setup  -  Step 1 of 2 (bootstrap)'
if ($Uninstall) { Write-Host '[MODE] Uninstall - this run will remove the toolchain, not install it.' -ForegroundColor Magenta }
Write-Debug2 "RepositoryUrl  = $RepositoryUrl"
Write-Debug2 "RepositoryName = $RepositoryName"
Write-Debug2 "PSVersion      = $($PSVersionTable.PSVersion)"
Write-Debug2 "Uninstall      = $([bool]$Uninstall)"

# ---- 0. Elevate FIRST, before any checks/installs --------------------
# Git's own installer (and later, Chocolatey/choco installs) require admin
# rights. If this script isn't already elevated, those steps trigger their
# own separate UAC consent prompts mid-flow - confusing and disruptive.
# Elevating up front means the whole chain (Git install, clone, and the
# handoff to setupc.ps1, which inherits this elevated token automatically)
# runs under a single UAC prompt with no further interruptions.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn2 'Administrator rights required. Relaunching elevated before any checks run...'
    $elevateArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$PSCommandPath`"")
    if ($ClonePath)        { $elevateArgs += @('-ClonePath', "`"$ClonePath`"") }
    if ($script:DebugMode) { $elevateArgs += '-Debug' }
    if ($Uninstall)        { $elevateArgs += '-Uninstall' }
    if ($CI)               { $elevateArgs += '-CI' }
    try {
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $elevateArgs -PassThru -Wait
    } catch { Fail 'Elevation was declined. Re-run from an Administrator PowerShell.' }

    # Force-close this (original, pre-elevation) window outright. Plain `exit`
    # is not enough when this script was launched via "Run with PowerShell" or
    # a shortcut using -NoExit - those keep the host process (and its window)
    # alive after the script returns, leaving a stale idle prompt behind.
    # -CI never waits on a prompt, even combined with -Debug.
    if ($script:DebugMode -and -not $CI) {
        Write-Host "`n[debug] Elevated window finished (exit $($proc.ExitCode)). Press Enter to close this original window..." -ForegroundColor DarkGray
        [void](Read-Host)
        exit $proc.ExitCode
    }
    Stop-Process -Id $PID -Force
}

# Fresh PATH before any "is it already installed" checks, so tools that are
# genuinely already present (from an earlier run/session) are correctly
# detected instead of being reported missing due to a stale inherited PATH.
Update-SessionPath

# ---- 1. Look for an existing local clone, then choose clone location -
$defaultParent = [Environment]::GetFolderPath('MyDocuments')

function Get-NormalizedRepoUrl {
    param([string] $Url)
    if (-not $Url) { return '' }
    ($Url.Trim().TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
}

# Reads the origin remote URL directly out of .git/config (no git.exe needed),
# so this works even before Git is installed - which matters now that the
# directory check runs before the Git check.
function Get-OriginUrlFromGitConfig {
    param([string] $Path)
    $configPath = Join-Path $Path '.git\config'
    if (-not (Test-Path $configPath)) { return $null }
    $content = Get-Content -Raw -Path $configPath -ErrorAction SilentlyContinue
    if (-not $content) { return $null }
    $m = [regex]::Match($content, '\[remote\s+"origin"\][^\[]*?\burl\s*=\s*(\S+)', 'IgnoreCase, Singleline')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# A candidate folder counts as "this repo" only if it's a Git repo whose
# origin remote actually matches - not just a folder name guess.
function Test-IsMatchingClone {
    param([string] $Path)
    $origin = Get-OriginUrlFromGitConfig -Path $Path
    if (-not $origin) { return $false }
    return (Get-NormalizedRepoUrl $origin) -eq (Get-NormalizedRepoUrl $RepositoryUrl)
}

# Searches the current directory and common user dev folders for an existing
# clone of this repository, so we don't clone a fresh copy the user already has.
function Find-ExistingClone {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($PWD.Path) {
        $candidates.Add($PWD.Path)                                   # cwd IS the repo
        $candidates.Add((Join-Path $PWD.Path $RepositoryName))        # cwd contains it
    }
    if ($PSScriptRoot -and $PSScriptRoot -ne $PWD.Path) {
        $candidates.Add($PSScriptRoot)
        $candidates.Add((Join-Path $PSScriptRoot $RepositoryName))
    }

    $userDataRoots = @(
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'source\repos'),
        (Join-Path $env:USERPROFILE 'Projects'),
        (Join-Path $env:USERPROFILE 'Code'),
        (Join-Path $env:USERPROFILE 'dev'),
        (Join-Path $env:USERPROFILE 'git')
    )
    foreach ($root in $userDataRoots) {
        if ($root) { $candidates.Add((Join-Path $root $RepositoryName)) }
    }

    $seen = @{}
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $full = try { [System.IO.Path]::GetFullPath($c) } catch { continue }
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        Write-Debug2 "checking candidate: $full"
        if ((Test-Path $full) -and (Test-IsMatchingClone $full)) { return $full }
    }
    return $null
}

function Select-FolderDialog {
    param([string] $InitialPath, [string] $Description)
    $worker = {
        param($init, $desc)
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $desc; $dialog.SelectedPath = $init; $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        return (& $worker $InitialPath $Description)
    }
    $ps = [PowerShell]::Create()
    $ps.Runspace = [RunspaceFactory]::CreateRunspace()
    $ps.Runspace.ApartmentState = 'STA'; $ps.Runspace.Open()
    [void]$ps.AddScript($worker).AddArgument($InitialPath).AddArgument($Description)
    $result = $ps.Invoke() | Select-Object -First 1
    $ps.Runspace.Close(); $ps.Dispose()
    return $result
}

$targetDir = $null

if ($Uninstall) {
    # Uninstall never clones and never installs Git: there's nothing to clone
    # into, and no installer (Git's or otherwise) should run just to remove
    # software. Locate where to run setupc.ps1 -Uninstall from, silently -
    # no interactive prompts, since there's no location decision to make.
    Write-Info 'Repository location'
    Write-StatusLine -Component 'Repository' -Status 'locating (uninstall - no prompts, no clone)...'

    if ($ClonePath -and (Test-Path (Join-Path (Join-Path $ClonePath $RepositoryName) '.git'))) {
        $targetDir = Join-Path $ClonePath $RepositoryName
    }
    if (-not $targetDir) {
        $existing = Find-ExistingClone
        if ($existing) { $targetDir = $existing }
    }
    if (-not $targetDir -and $PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'setupc.ps1'))) {
        # A local setupc.ps1 (+ packages.config) override next to this script
        # is enough on its own - no real repo checkout is required to uninstall.
        $targetDir = $PSScriptRoot
    }

    if (-not $targetDir) {
        Write-StatusLine -Component 'Repository' -Status 'not found' -Kind fail -Final
        Fail 'Uninstall needs either an existing local clone of the repository, or a setupc.ps1 (and packages.config) placed next to setup.ps1 for troubleshooting. Neither was found.'
    }
    Write-StatusLine -Component 'Repository' -Status ("using {0}" -f $targetDir) -Kind ok -Final
    Write-Debug2 "targetDir = $targetDir"
}
else {
    Write-Info 'Repository location'

    if ($CI) {
        # Same directory logic as the interactive path below, minus the
        # prompts: look for an existing clone (current/script dir, then
        # common dev folders including Documents), and if nothing is found,
        # silently default to Documents with no confirmation.
        Write-StatusLine -Component 'Repository' -Status 'locating (CI - no prompts)...'

        if ($ClonePath) {
            $parentDir = $ClonePath
        }
        else {
            $existing = Find-ExistingClone
            if ($existing) {
                $targetDir = $existing
                Write-StatusLine -Component 'Repository' -Status ("found existing clone: {0}" -f $existing) -Kind ok -Final
            }
            else {
                $parentDir = $defaultParent
                Write-StatusLine -Component 'Repository' -Status ("no existing clone found, using default: {0}" -f $defaultParent) -Kind ok -Final
            }
        }
    }
    elseif ($ClonePath) {
        $parentDir = $ClonePath
    }
    else {
        Write-StatusLine -Component 'Repository' -Status 'checking for an existing local clone...'
        $existing = Find-ExistingClone

        if ($existing) {
            Write-StatusLine -Component 'Repository' -Status ("found existing clone: {0}" -f $existing) -Kind ok -Final
            Write-Host ''
            Write-Host "An existing local clone of this repository was found at:" -ForegroundColor White
            Write-Host "$existing" -ForegroundColor Yellow
            Write-Host ''
            Write-Host "[Y] Yes, use this clone" -ForegroundColor White
            Write-Host "[N] No, choose a different folder" -ForegroundColor White
            Write-Host ''
            do { $answer = (Read-Host 'Type Y to use it or N to choose a folder').Trim().ToUpper() } while ($answer -notin @('Y','N'))

            if ($answer -eq 'Y') { $targetDir = $existing }
        }
        else {
            Write-StatusLine -Component 'Repository' -Status 'no existing clone found' -Kind ok -Final
        }

        if (-not $targetDir) {
            Write-Host ''
            Write-Host "The repository will be cloned into:" -ForegroundColor White
            Write-Host "$defaultParent\$RepositoryName" -ForegroundColor Yellow
            Write-Host ''
            Write-Host "[Y] Yes, continue with this location" -ForegroundColor White
            Write-Host "[N] No, let me choose a different folder" -ForegroundColor White
            Write-Host ''
            do { $answer = (Read-Host 'Type Y to continue or N to choose a folder').Trim().ToUpper() } while ($answer -notin @('Y','N'))

            if ($answer -eq 'Y') { $parentDir = $defaultParent }
            else {
                Write-Warn2 'Opening folder picker...'
                $picked = Select-FolderDialog -InitialPath $defaultParent -Description 'Select the folder to clone the repository into'
                if (-not $picked) { Fail 'No folder was selected. Setup cancelled.' }
                $parentDir = $picked
            }
        }
    }

    if (-not $targetDir) { $targetDir = Join-Path $parentDir $RepositoryName }
    Write-Debug2 "targetDir = $targetDir"

    # ---- 2. Git: checking -> installing -> verifying -> installed --------
    Write-Info 'Version control'
    Write-StatusLine -Component 'Git' -Status 'checking...'
    $git = Get-ToolVersion -Commands @('git')

    if ($git.Found) {
        Write-Debug2 "git at $($git.Path)"
        Write-StatusLine -Component 'Git' -Status ("already installed  {0}" -f $git.Version) -Kind ok -Final
    }
    else {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-StatusLine -Component 'Git' -Status 'winget unavailable' -Kind fail -Final
            Fail 'winget is not available. Install "App Installer" from the Microsoft Store (or Git from https://git-scm.com) and re-run.'
        }

        # Already elevated (see step 0), so this runs with no further UAC prompt.
        # --silent here is what keeps Git's own installer UI hidden in normal
        # (non-debug) runs; -Debug flips it to --interactive so the native
        # installer UI is shown, consistent with how Chocolatey installs behave.
        $wingetArgs = @('install','--id','Git.Git','--exact','--source','winget','--accept-package-agreements','--accept-source-agreements')
        if ($script:DebugMode) { $wingetArgs += '--interactive' } else { $wingetArgs += '--silent' }

        $wingetDetailer = { param($l) if ($l -match 'Download') { 'downloading...' } elseif ($l -match 'install') { 'installing...' } else { $null } }
        $code = Invoke-Managed -FilePath 'winget' -ArgumentList $wingetArgs -Component 'Git' -Status 'installing...' -Detailer $wingetDetailer
        Write-Debug2 "winget exit code $code"

        Update-SessionPath
        Write-StatusLine -Component 'Git' -Status 'verifying...'
        $git = Get-ToolVersion -Commands @('git')
        if (-not $git.Found) {
            Write-StatusLine -Component 'Git' -Status 'verification failed (not on PATH)' -Kind fail -Final
            Fail 'Git was installed but is not on PATH. Close this window, open a NEW PowerShell, and re-run setup.ps1.'
        }
        Write-StatusLine -Component 'Git' -Status ("installed  {0}" -f $git.Version) -Kind ok -Final
    }

    # ---- 3. Clone -------------------------------------------------------
    Write-Info 'Clone'
    Write-StatusLine -Component 'Repository' -Status 'checking...'

    if (Test-Path $targetDir) {
        if (Test-Path (Join-Path $targetDir '.git')) {
            Write-StatusLine -Component 'Repository' -Status 'already cloned (reusing)' -Kind ok -Final
            # Cover clones made before --recurse-submodules was added below,
            # or where a submodule (e.g. vcpkg) was never initialized.
            $subCode = Invoke-Managed -FilePath 'git' -ArgumentList @('-C',$targetDir,'submodule','update','--init','--recursive') -Component 'Repository' -Status 'syncing submodules...'
            if ($subCode -ne 0) { Write-Warn2 "git submodule update failed (exit $subCode) - submodules may be missing." }
        }
        else {
            Write-StatusLine -Component 'Repository' -Status 'target exists, not a repo' -Kind fail -Final
            Fail "The folder '$targetDir' already exists and is not a Git repository. Move or remove it, then re-run setup.ps1."
        }
    }
    else {
        if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
        $cloneDetailer = { param($l) if ($l -match '(Receiving|Resolving|Compressing) objects:\s*(\d{1,3})%') { "$($matches[1].ToLower()) $($matches[2])%" } elseif ($l -match 'Cloning into') { 'cloning...' } else { $null } }
        $code = Invoke-Managed -FilePath 'git' -ArgumentList @('clone','--recurse-submodules','--progress',$RepositoryUrl,$targetDir) -Component 'Repository' -Status 'cloning...' -Detailer $cloneDetailer
        if ($code -ne 0 -or -not (Test-Path (Join-Path $targetDir '.git'))) {
            Write-StatusLine -Component 'Repository' -Status ("clone failed (git exit {0})" -f $code) -Kind fail -Final
            Fail 'git clone failed. Check the repository URL and your network connection.'
        }
        Write-StatusLine -Component 'Repository' -Status 'cloned' -Kind ok -Final
    }
}

# ---- 4. Hand off to setupc.ps1, then close this window --------------
# For local troubleshooting: if a setupc.ps1 sits next to THIS script, prefer
# it over the one in the cloned repo. The repo is still passed as -RepoRoot so
# the README (and, unless overridden, packages.config) come from the clone.
Write-Info 'Handing off to the project installer...'
$localSetup = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'setupc.ps1' } else { $null }
$repoSetupc = Join-Path $targetDir 'setupc.ps1'
if ($localSetup -and (Test-Path $localSetup)) {
    $repoSetup = $localSetup
    Write-Warn2 "Using local setupc.ps1 next to setup.ps1 (troubleshooting): $repoSetup"
}
elseif (Test-Path $repoSetupc) {
    $repoSetup = $repoSetupc
}
else {
    Fail "Could not find setupc.ps1 next to setup.ps1 or in the repository at '$repoSetupc'."
}

$hostExe = (Get-Process -Id $PID).Path
$argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$repoSetup`"",'-RepoRoot',"`"$targetDir`"")
if ($script:DebugMode) { $argList += '-Debug' }
if ($Uninstall)        { $argList += '-Uninstall' }
if ($CI)               { $argList += '-CI' }
Write-Debug2 ("launch: {0} {1}" -f $hostExe, ($argList -join ' '))
Start-Process -FilePath $hostExe -ArgumentList $argList

Write-Host "Installer launched in a new window. Closing this one." -ForegroundColor Green

if ($script:DebugMode -and -not $CI) {
    Write-Host "`n[debug] Press Enter to close this bootstrap window..." -ForegroundColor DarkGray
    [void](Read-Host)
    exit 0
}

# Force-close this window/process outright. Plain `exit` is not enough when
# this script was launched via "Run with PowerShell" or a shortcut using
# -NoExit, since those keep the host process (and its window) alive after
# the script returns. Killing our own PID closes the window unconditionally.
Start-Sleep -Milliseconds 800
Stop-Process -Id $PID -Force

<#
.SYNOPSIS
    Project toolchain installer & verifier (setupc.ps1).

.DESCRIPTION
    Step 2 of a two-step install process. Launched by the downloaded bootstrap
    (setup.ps1, which lives in Downloads) after the repository is cloned; can
    also be run directly. Canonical layout: this script lives in
    <repo>\scripts\setupc.ps1, and packages.config lives at the repo root
    (<repo>\packages.config) - one level up from this script.

    It installs the toolchain declared in <repo>\packages.config with
    Chocolatey, presenting a clean per-component status UI:

        checking... -> installing... (live choco progress) -> verifying... -> installed vX

    Each component is verified by actually running the tool and capturing its
    version. Installer UIs are suppressed during normal runs (silent install +
    spinner). Chocolatey's progress is surfaced, but its firehose of detail is
    filtered out.

.PARAMETER Debug
    Verbose troubleshooting mode: full file paths and variables are printed,
    installers run visibly (native UI, auto-run), Chocolatey runs with
    --verbose --debug, and raw command output is shown instead of the spinner.
    Combine with -Uninstall for a verbose uninstall.

.PARAMETER Uninstall
    Instead of installing, uninstalls every package listed in packages.config
    via Chocolatey (does not touch Chocolatey itself). Does not open the
    README. If Chocolatey isn't installed, there is nothing to do and the
    script exits immediately. MSYS2 (if listed) is force-cleaned afterward
    regardless of what Chocolatey's own bookkeeping reports, since its
    install directory can outlive Chocolatey's record of it.

.PARAMETER CI
    Fully unattended: never waits on a Read-Host prompt (even combined with
    -Debug), and never opens README.md/VS Code. Everything else (install,
    verify, and - on success - the project build) still runs the same as an
    interactive run.

.NOTES
    Requires an elevated (Administrator) PowerShell; self-elevates if needed.

        powershell -ExecutionPolicy Bypass -File .\setupc.ps1
        powershell -ExecutionPolicy Bypass -File .\setupc.ps1 -Debug
        powershell -ExecutionPolicy Bypass -File .\setupc.ps1 -Uninstall
        powershell -ExecutionPolicy Bypass -File .\setupc.ps1 -Uninstall -Debug
        powershell -ExecutionPolicy Bypass -File .\setupc.ps1 -CI
#>

# NOTE: no [CmdletBinding()] on purpose, so that -Debug binds to our own switch
# (a verbosity MODE) instead of PowerShell's common -Debug parameter.
param(
    [string] $RepoRoot,
    [switch] $Debug,
    [switch] $Uninstall,
    [switch] $CI
)

$ErrorActionPreference = 'Stop'

# ======================================================================
# UI / status helpers.
# NOTE: this block is intentionally duplicated in setup.ps1 so each script
# is self-contained. Keep the two copies in sync.
# ======================================================================
$script:DebugMode = [bool]$Debug
$script:Failures  = @()

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

# Renders one component's status on a single, self-updating line.
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
        if ($PSBoundParameters.ContainsKey('Frame')) { return }   # skip spinner spam in debug
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

# Runs a native process.
#   normal : output captured; spinner + filtered progress on one status line.
#   debug  : process runs visibly with full native output (installer UI shown).
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
    # CreateNoWindow only suppresses a CONSOLE window - it has no effect on
    # GUI-subsystem executables (e.g. an Inno Setup unins000.exe). WindowStyle
    # is passed through as an initial "start hidden" hint, but NOTE: tested
    # empirically against a real Win32 GUI app (charmap.exe) and confirmed
    # this hint does NOT reliably suppress a window the target app explicitly
    # calls ShowWindow() for - it's a best-effort addition, not a guarantee.
    # The actual, reliable suppression for Inno Setup uninstallers has to
    # come from the target's OWN silent flag (/VERYSILENT) - see callers.
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

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

# Filters Chocolatey's output down to progress-only detail, clearly
# differentiating the download phase (with a live percentage that also
# drives Invoke-Managed's Write-Progress bar) from the install phase
# (no live percentage - just a phase label + spinner).
$script:ChocoDetailer = {
    param($line)
    if     ($line -match 'Progress:.*?(\d{1,3})\s*%')  { "downloading  $($matches[1])%" }
    elseif ($line -match '^\s*Downloading\b')          { 'downloading...' }
    elseif ($line -match '^\s*Extracting\b')           { 'extracting...' }
    elseif ($line -match '^\s*Installing\b')           { 'installing...' }
    else { $null }
}

# Verifies a tool by running it and returning its version.
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

# Locates the VS Code launcher via PATH first, then known install locations,
# so README.md is always opened in VS Code - never the OS default .md handler.
function Find-VSCodeExe {
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command code.cmd -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }

    $known = @(
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd')
    )
    if (${env:ProgramFiles(x86)}) { $known += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd') }

    foreach ($k in $known) { if ($k -and (Test-Path $k)) { return $k } }
    return $null
}

# Launches VS Code, then toggles its native Full Screen mode (the same F11
# a user would press - View > Appearance > Full Screen). VS Code's CLI has
# no --fullscreen flag, so this drives it via the actual keystroke.
#
# Verified empirically (not just assumed) end to end on a real machine:
#   - code.cmd/code is just a launcher that spawns the real Code.exe and
#     exits immediately, so this polls briefly for that real GUI process.
#   - SetForegroundWindow alone is unreliable from a script - Windows'
#     foreground-lock restriction can silently no-op it - so this first
#     does the classic fake-ALT-keypress workaround to reset that lock.
#   - Even with confirmed focus, VS Code (Electron) isn't immediately ready
#     to process synthetic key input the instant its window appears; without
#     an extra settle delay here, F11 was reliably swallowed. 3 seconds was
#     confirmed sufficient in testing (window went from title-barred/windowed
#     to exactly the full screen resolution, borders included).
# Best effort throughout: if any step fails, VS Code still opens normally,
# just not full-screen.
function Open-VSCodeFullScreen {
    param([string] $CodeExe, [string] $RepoRoot, [string] $ReadmePath)

    # Direct invocation, not Start-Process: code.cmd is a batch launcher, and
    # Start-Process spawning it opens its own brief but visible console
    # window ("black box") before it hands off to the real Code.exe. Calling
    # it directly runs it inline in this process's own console instead - no
    # extra window. Confirmed: returns in ~1s once it hands off (this is
    # code.cmd's own launcher process exiting, not the GUI closing).
    & $CodeExe $RepoRoot $ReadmePath

    try {
        Add-Type -AssemblyName System.Windows.Forms
        if (-not ('Native.Win32' -as [type])) {
            Add-Type -Namespace Native -Name Win32 -MemberDefinition @'
                [DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
                [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
                [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
'@
        }
    }
    catch {
        Write-Debug2 "could not load Win32 window helpers: $($_.Exception.Message)"
        return
    }

    $codeProc = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        $codeProc = Get-Process -Name 'Code' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($codeProc) { break }
    }
    if (-not $codeProc) {
        Write-Debug2 "could not locate the VS Code window to toggle full screen"
        return
    }

    # Let the Electron renderer finish initializing before we touch it.
    Start-Sleep -Seconds 3

    [Native.Win32]::ShowWindow($codeProc.MainWindowHandle, 9) | Out-Null   # SW_RESTORE, in case it started minimized
    # Fake ALT keypress resets Windows' foreground-lock timer, without which
    # SetForegroundWindow can silently fail when called from a background script.
    [Native.Win32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)               # ALT down
    [Native.Win32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)               # ALT up
    [Native.Win32]::SetForegroundWindow($codeProc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('{F11}')
}

# The standard Chocolatey msys2 package install root. Chocolatey's own
# $env:ChocolateyToolsLocation (default C:\tools) is where msys64 lands.
function Get-Msys2Root {
    $toolsRoot = if ($env:ChocolateyToolsLocation) { $env:ChocolateyToolsLocation } else { 'C:\tools' }
    Join-Path $toolsRoot 'msys64'
}

# Persists a directory into the MACHINE-WIDE PATH (registry), not just this
# process's in-memory copy. Update-SessionPath only ever updates the current
# process - without this, a tool that doesn't add itself to PATH via its own
# installer (like a pacman-installed MinGW toolchain) would only ever resolve
# inside setupc.ps1 itself, and stay invisible to every other terminal
# (including the one actually used to build the project). Idempotent.
function Add-MachinePathEntry {
    param([string] $Directory)
    if (-not (Test-Path $Directory)) { return }
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $machinePath -split ';' | Where-Object { $_ }
    if ($parts -contains $Directory) {
        Write-Debug2 "already on machine PATH: $Directory"
        return
    }
    [System.Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'Machine')
    Write-Debug2 "added to machine PATH: $Directory"
}

# The uninstall counterpart to Add-MachinePathEntry. Idempotent.
function Remove-MachinePathEntry {
    param([string] $Directory)
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $machinePath -split ';' | Where-Object { $_ }
    if ($parts -notcontains $Directory) {
        Write-Debug2 "not on machine PATH (nothing to remove): $Directory"
        return
    }
    $newParts = $parts | Where-Object { $_ -ne $Directory }
    [System.Environment]::SetEnvironmentVariable('Path', ($newParts -join ';'), 'Machine')
    Write-Debug2 "removed from machine PATH: $Directory"
}

# Rebuilds this session's PATH from the registry (Machine + User) plus known
# toolchain bin folders, so freshly installed apps resolve immediately.
function Update-SessionPath {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = @(
        (Join-Path $env:ProgramData 'chocolatey\bin'),
        (Join-Path $env:ProgramFiles 'LLVM\bin'),
        (Join-Path $env:ProgramFiles 'CMake\bin'),
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin'),
        (Join-Path (Get-Msys2Root) 'mingw64\bin')
    )
    if (${env:ProgramFiles(x86)}) { $extra += (Join-Path ${env:ProgramFiles(x86)} 'CMake\bin') }
    $parts = @($machinePath, $userPath) + $extra |
        Where-Object { $_ } | ForEach-Object { $_ -split ';' } |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $env:Path = ($parts -join ';')
    Write-Debug2 "PATH refreshed ($($parts.Count) entries)"
}

# Re-checks a just-installed tool a few times with a short settle delay
# between attempts, refreshing PATH each time. A freshly finished installer
# can have a brief lag before its disk/registry writes are fully visible to
# a new process lookup; a single immediate check can catch that gap and
# report a false failure. Returns on the first success; no extra delay when
# things are already working.
function Wait-ForToolVerified {
    param([string[]] $VerifyCmds, [string] $VerifyArg = '--version', [int] $Retries = 3, [int] $DelayMs = 700)
    for ($i = 1; $i -le $Retries; $i++) {
        Update-SessionPath
        $result = Get-ToolVersion -Commands $VerifyCmds -VersionArg $VerifyArg
        if ($result.Found) { return $result }
        Write-Debug2 "verify attempt $i/$Retries not found yet"
        if ($i -lt $Retries) { Start-Sleep -Milliseconds $DelayMs }
    }
    return $result
}

# Installs one Chocolatey package and drives its status UI end to end.
function Install-Component {
    param(
        [string]   $ChocoId,
        [string]   $Label,
        [string[]] $VerifyCmds,
        [string]   $VerifyArg = '--version',
        [string[]] $ExtraCmds
    )
    Write-Debug2 "component id=$ChocoId label=$Label verify=[$($VerifyCmds -join ',')] extra=[$($ExtraCmds -join ',')]"

    # Defensive refresh before every check: cheap, and guards against a prior
    # component's install (or the very first check of the run) leaving PATH
    # stale relative to what's actually on disk/registry right now.
    Update-SessionPath
    Write-StatusLine -Component $Label -Status 'checking...'
    $pre = Get-ToolVersion -Commands $VerifyCmds -VersionArg $VerifyArg
    if ($pre.Found) {
        Write-Debug2 "already present at $($pre.Path)"
        Write-StatusLine -Component $Label -Status ("already installed  {0}" -f $pre.Version) -Kind ok -Final
        return $true
    }

    # --force is required here: we only reach this point because our OWN check
    # (Get-ToolVersion) says the tool isn't actually usable. Chocolatey may
    # still believe the package is already installed - e.g. a stale/partial
    # install from an earlier run (a metapackage like "cmake" pulling in
    # "cmake.install" as a dependency without the right installArguments
    # leaves cmake.install "installed" with no cmake.exe ever placed on disk).
    # Without --force, choco silently no-ops on an "already installed"
    # package and never re-runs the installer, so the tool stays missing
    # forever. --force always re-runs the install script for real.
    $args = @('install', $ChocoId, '--yes', '--force')
    if ($script:DebugMode) { $args += @('--verbose', '--debug', '--not-silent') }
    $code = Invoke-Managed -FilePath 'choco' -ArgumentList $args -Component $Label -Status 'installing...' -Detailer $script:ChocoDetailer
    if ($code -ne 0 -and $code -ne 3010) {
        Write-StatusLine -Component $Label -Status ("install failed (choco exit {0})" -f $code) -Kind fail -Final
        $script:Failures += $Label
        return $false
    }

    Write-StatusLine -Component $Label -Status 'verifying...'
    $post = Wait-ForToolVerified -VerifyCmds $VerifyCmds -VerifyArg $VerifyArg

    if (-not $post.Found) {
        # Recovery path for a broken/partial prior install: Chocolatey's
        # package registration can be corrupt enough that even --force
        # skips re-running the real installer. Wipe the registration and
        # do a clean install once before giving up.
        Write-Debug2 "still not found after forced install; retrying via uninstall+install"
        Write-StatusLine -Component $Label -Status 'retrying (clean reinstall)...'
        $retryUninstallArgs = @('uninstall', $ChocoId, '--yes', '--force')
        $retryInstallArgs   = @('install', $ChocoId, '--yes', '--force')
        if ($script:DebugMode) {
            $retryUninstallArgs += @('--verbose', '--debug', '--not-silent')
            $retryInstallArgs   += @('--verbose', '--debug', '--not-silent')
        }
        Invoke-Managed -FilePath 'choco' -ArgumentList $retryUninstallArgs -Component $Label -Status 'removing stale install...' | Out-Null
        $code = Invoke-Managed -FilePath 'choco' -ArgumentList $retryInstallArgs -Component $Label -Status 'reinstalling...' -Detailer $script:ChocoDetailer
        $post = Wait-ForToolVerified -VerifyCmds $VerifyCmds -VerifyArg $VerifyArg
    }

    if (-not $post.Found) {
        Write-StatusLine -Component $Label -Status 'verification failed (not on PATH)' -Kind fail -Final
        $script:Failures += $Label
        return $false
    }

    $extraNote = ''
    if ($ExtraCmds) {
        foreach ($ec in $ExtraCmds) {
            $ev = Get-ToolVersion -Commands @($ec) -VersionArg $VerifyArg
            if (-not $ev.Found) {
                Write-StatusLine -Component $Label -Status ("verified, but '{0}' missing" -f $ec) -Kind fail -Final
                $script:Failures += "$Label/$ec"
                return $false
            }
            Write-Debug2 "extra ok: $ec -> $($ev.Version) @ $($ev.Path)"
        }
        $extraNote = ' (+' + ($ExtraCmds -join ', ') + ')'
    }

    Write-Debug2 "verified $($post.Path)"
    Write-StatusLine -Component $Label -Status ("installed  {0}{1}" -f $post.Version, $extraNote) -Kind ok -Final
    return $true
}

# Fallback for when Chocolatey has no record of a package (its bookkeeping
# and the real installed state have drifted apart - e.g. an interrupted or
# externally-run install/uninstall) so `choco uninstall` is a silent no-op
# even though the real program is still on disk. Generic, not tool-specific:
# walks up from the resolved binary looking for a standard Inno Setup
# uninstaller (unins000.exe), which most GUI installers (Git, VS Code, ...)
# ship next to their install root.
function Invoke-NativeUninstallFallback {
    param([string] $Label, [string] $BinaryPath)
    if (-not $BinaryPath) { return $false }
    $dir = Split-Path -Parent $BinaryPath
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
        $uninst = Join-Path $dir 'unins000.exe'
        if (Test-Path $uninst) {
            Write-Debug2 "no choco record for this package, but found a native uninstaller at $uninst"
            # Same silent-by-default / visible-in-debug convention as everywhere else.
            $args = if ($script:DebugMode) { @() } else { @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES') }
            Invoke-Managed -FilePath $uninst -ArgumentList $args -Component $Label -Status 'uninstalling (native, no choco record)...' | Out-Null
            return $true
        }
        $dir = Split-Path -Parent $dir
    }
    return $false
}

# Uninstalls one Chocolatey package and drives its status UI end to end.
# Ground truth is our own command resolution (same philosophy as
# Install-Component), not choco's exit code, since choco's own bookkeeping
# can be stale or version-dependent about "not installed" outcomes.
function Uninstall-Component {
    param(
        [string]   $ChocoId,
        [string]   $Label,
        [string[]] $VerifyCmds,
        [string]   $VerifyArg = '--version'
    )
    Write-Debug2 "component id=$ChocoId label=$Label verify=[$($VerifyCmds -join ',')]"

    Update-SessionPath
    Write-StatusLine -Component $Label -Status 'checking...'
    $pre = Get-ToolVersion -Commands $VerifyCmds -VersionArg $VerifyArg
    Write-Debug2 "pre-uninstall: found=$($pre.Found) path=$($pre.Path)"

    $args = @('uninstall', $ChocoId, '--yes', '--force')
    if ($script:DebugMode) { $args += @('--verbose', '--debug', '--not-silent') }
    $code = Invoke-Managed -FilePath 'choco' -ArgumentList $args -Component $Label -Status 'uninstalling...' -Detailer $script:ChocoDetailer
    Write-Debug2 "choco uninstall exit code: $code"

    Update-SessionPath
    $post = Get-ToolVersion -Commands $VerifyCmds -VersionArg $VerifyArg

    if ($post.Found -and $pre.Found) {
        if (Invoke-NativeUninstallFallback -Label $Label -BinaryPath $pre.Path) {
            Update-SessionPath
            $post = Get-ToolVersion -Commands $VerifyCmds -VersionArg $VerifyArg
        }
    }

    if (-not $post.Found) {
        $status = if ($pre.Found) { 'uninstalled' } else { 'was not installed' }
        Write-StatusLine -Component $Label -Status $status -Kind ok -Final
        return $true
    }

    Write-StatusLine -Component $Label -Status 'still present after uninstall' -Kind fail -Final
    $script:Failures += $Label
    return $false
}

# Installs the MinGW-w64 GCC toolchain into an existing MSYS2 install via
# pacman, so vcpkg's x64-mingw-static/x64-mingw-dynamic triplets have a real
# compiler to build against. Not a Chocolatey package itself - Chocolatey's
# msys2 package only provides the base pacman environment, and the actual
# toolchain is a package pacman installs afterward - but this follows the
# same checking/installing/verifying UI and "only reinstall if verification
# fails" convention as everything else. Install-only: uninstalling MSYS2
# itself (via Uninstall-Component, above) removes this along with it, since
# it all lives inside MSYS2's own install directory.
function Install-MinGWToolchain {
    $label    = 'MinGW-w64'
    $msys2    = Get-Msys2Root
    $pacman   = Join-Path $msys2 'usr\bin\pacman.exe'
    $mingwBin = Join-Path $msys2 'mingw64\bin'
    $gccPath  = Join-Path $mingwBin 'gcc.exe'

    Write-StatusLine -Component $label -Status 'checking...'
    if (-not (Test-Path $pacman)) {
        Write-StatusLine -Component $label -Status 'MSYS2 not found - skipping' -Kind fail -Final
        $script:Failures += $label
        return $false
    }

    $pre = Get-ToolVersion -Commands @($gccPath) -VersionArg '--version'
    if ($pre.Found) {
        Write-Debug2 "already present at $($pre.Path)"
        # Unconditional, even when already installed: pacman never adds
        # itself to the system PATH the way normal Windows installers do, so
        # a prior run could have installed the compiler but never persisted
        # this - re-running setupc.ps1 must be able to fix that on its own.
        Add-MachinePathEntry -Directory $mingwBin
        Update-SessionPath
        Write-StatusLine -Component $label -Status ("already installed  {0}" -f $pre.Version) -Kind ok -Final
        return $true
    }

    # pacman's first sync/update pass also updates its own core runtime and
    # can exit oddly as a result (a well-known, documented MSYS2 quirk) - run
    # it twice and only treat the SECOND pass's exit code as meaningful.
    Invoke-Managed -FilePath $pacman -ArgumentList @('-Syuu', '--noconfirm') -Component $label -Status 'updating MSYS2 core (pass 1)...' | Out-Null
    $code = Invoke-Managed -FilePath $pacman -ArgumentList @('-Syuu', '--noconfirm') -Component $label -Status 'updating MSYS2 core (pass 2)...'
    Write-Debug2 "pacman -Syuu (pass 2) exit code: $code"
    if ($code -ne 0) {
        Write-StatusLine -Component $label -Status ("MSYS2 core update failed (exit {0})" -f $code) -Kind fail -Final
        $script:Failures += $label
        return $false
    }

    $code = Invoke-Managed -FilePath $pacman -ArgumentList @('-S', '--needed', '--noconfirm', 'mingw-w64-x86_64-toolchain') -Component $label -Status 'installing toolchain...'
    Write-Debug2 "pacman toolchain install exit code: $code"
    if ($code -ne 0) {
        Write-StatusLine -Component $label -Status ("toolchain install failed (exit {0})" -f $code) -Kind fail -Final
        $script:Failures += $label
        return $false
    }

    Add-MachinePathEntry -Directory $mingwBin
    Write-StatusLine -Component $label -Status 'verifying...'
    $post = Wait-ForToolVerified -VerifyCmds @($gccPath) -VerifyArg '--version'
    if (-not $post.Found) {
        Write-StatusLine -Component $label -Status 'verification failed (gcc.exe not found)' -Kind fail -Final
        $script:Failures += $label
        return $false
    }

    Write-Debug2 "verified $($post.Path)"
    Write-StatusLine -Component $label -Status ("installed  {0}" -f $post.Version) -Kind ok -Final
    return $true
}

# Guarantees MSYS2 (and the MinGW-w64 toolchain living inside it) is FULLY
# gone, regardless of what Chocolatey's own bookkeeping believes. Confirmed
# directly on a real machine: "choco uninstall msys2" can complete (or even
# report the package as already gone from its own registry) while the
# extracted C:\tools\msys64 directory - including everything pacman later
# installed into mingw64\bin - is still sitting on disk. This is the same
# class of choco/reality drift we've hit with other packages, just with no
# native uninstaller to fall back on (it's a zip extraction, not an
# installer), so the only reliable fix is to force-remove the directory
# ourselves and clean up the PATH entry we added for it.
function Uninstall-MSYS2Cleanup {
    $label    = 'MSYS2'
    $msys2    = Get-Msys2Root
    $mingwBin = Join-Path $msys2 'mingw64\bin'

    if (-not (Test-Path $msys2)) {
        Write-Debug2 "MSYS2 root already gone: $msys2"
        return
    }

    Write-StatusLine -Component $label -Status 'removing leftover MSYS2/MinGW-w64 files...'
    try {
        Remove-Item -LiteralPath $msys2 -Recurse -Force -ErrorAction Stop
        Remove-MachinePathEntry -Directory $mingwBin
        Write-StatusLine -Component $label -Status 'fully removed' -Kind ok -Final
    }
    catch {
        Write-StatusLine -Component $label -Status ("cleanup failed: {0}" -f $_.Exception.Message) -Kind fail -Final
        $script:Failures += $label
    }
}

# ======================================================================
# Main
# ======================================================================
# Canonical layout: this script lives in <repo>\scripts\, so when run
# directly without -RepoRoot (e.g. double-clicked from inside the repo),
# the actual repo root is one level up from this script's own folder.
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot   = (Resolve-Path $RepoRoot).Path

# README is ALWAYS taken from the root of the cloned repository.
$ReadmePath = Join-Path $RepoRoot 'README.md'

# packages.config: for local troubleshooting, prefer a copy sitting next to this
# script; otherwise use the one in the cloned repo root.
$localPkg = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'packages.config' } else { $null }
$repoPkg  = Join-Path $RepoRoot 'packages.config'
if ($localPkg -and (Test-Path $localPkg) -and ($localPkg -ne $repoPkg)) {
    $PackagesFile = $localPkg
    $usingLocalPkg = $true
}
else {
    $PackagesFile = $repoPkg
    $usingLocalPkg = $false
}

$bannerTitle = 'Developer Machine Setup  -  Step 2 of 2 (toolchain)'
if ($Uninstall) { $bannerTitle = 'Developer Machine Setup  -  Uninstall toolchain' }
Write-Banner $bannerTitle
if ($Uninstall) { Write-Host '[MODE] Uninstall - packages listed in packages.config will be removed.' -ForegroundColor Magenta }
Write-Debug2 "RepoRoot     = $RepoRoot"
Write-Debug2 "PackagesFile = $PackagesFile"
Write-Debug2 "ReadmePath   = $ReadmePath"
Write-Debug2 "PSVersion    = $($PSVersionTable.PSVersion)"
Write-Debug2 "Uninstall    = $([bool]$Uninstall)"

# ---- 0. Elevate (Chocolatey needs Administrator) ---------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn2 'Administrator rights required. Relaunching elevated...'
    $argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File',"`"$PSCommandPath`"",'-RepoRoot',"`"$RepoRoot`"")
    if ($script:DebugMode) { $argList += '-Debug' }
    if ($Uninstall)        { $argList += '-Uninstall' }
    if ($CI)               { $argList += '-CI' }
    try {
        $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -PassThru -Wait
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
# genuinely already present (from an earlier run/session, or from setup.ps1's
# own Git install just before this) are correctly detected instead of being
# reported missing due to a stale inherited PATH.
Update-SessionPath

if (-not (Test-Path $PackagesFile)) { Fail "Could not find packages.config at '$PackagesFile'." }

# Friendly labels + verification commands per Chocolatey package id. Shared by
# both the install and uninstall paths.
$Meta = @{
    git             = @{ Label = 'Git';     Cmds = @('git');             Arg = '--version' }
    'git.install'   = @{ Label = 'Git';     Cmds = @('git');             Arg = '--version' }
    vscode          = @{ Label = 'VS Code'; Cmds = @('code','code.cmd'); Arg = '--version' }
    'vscode.install'= @{ Label = 'VS Code'; Cmds = @('code','code.cmd'); Arg = '--version' }
    llvm            = @{ Label = 'LLVM';    Cmds = @('clang');           Arg = '--version'; Extra = @('clang-format') }
    cmake           = @{ Label = 'CMake';   Cmds = @('cmake');           Arg = '--version' }
    'cmake.install' = @{ Label = 'CMake';   Cmds = @('cmake');           Arg = '--version' }
    ninja           = @{ Label = 'Ninja';   Cmds = @('ninja');           Arg = '--version' }
    # MSYS2 isn't meant to be on the general PATH (its own coreutils would
    # shadow Windows tools of the same name), so verify by full literal path
    # instead of a bare command name - Get-Command resolves a literal path
    # fine without needing its folder on PATH.
    msys2           = @{ Label = 'MSYS2';   Cmds = @((Join-Path (Get-Msys2Root) 'usr\bin\bash.exe')); Arg = '--version' }
}

try { [xml]$pkgXml = Get-Content -Raw -Path $PackagesFile } catch { Fail "packages.config is not valid XML: $($_.Exception.Message)" }
$ids = @($pkgXml.packages.package | ForEach-Object { [string]$_.id } | Where-Object { $_ })
if ($ids.Count -eq 0) { Fail 'packages.config lists no packages.' }
Write-Debug2 "packages: $($ids -join ', ')"

# ---- Uninstall mode: remove everything in packages.config, then exit ------
if ($Uninstall) {
    Write-Info 'Removing toolchain (from packages.config)'
    if ($usingLocalPkg) { Write-Warn2 "Using local packages.config next to setupc.ps1 (troubleshooting): $PackagesFile" }

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Warn2 'Chocolatey is not installed - nothing to uninstall.'
    }
    else {
        foreach ($id in $ids) {
            $m = $Meta[$id.ToLower()]
            if ($m) { Uninstall-Component -ChocoId $id -Label $m.Label -VerifyCmds $m.Cmds -VerifyArg $m.Arg | Out-Null }
            else    { Uninstall-Component -ChocoId $id -Label $id     -VerifyCmds @($id)                  | Out-Null }
        }
        # Force-cleanup backstop: MSYS2's install directory can outlive
        # Chocolatey's own record of it (confirmed on a real machine), so
        # this runs regardless of what Uninstall-Component above concluded.
        if ($ids -contains 'msys2') { Uninstall-MSYS2Cleanup }
    }

    Write-Info 'Summary'
    if ($script:Failures.Count -gt 0) {
        Write-Host ("[x] Some components could not be fully removed: {0}" -f ($script:Failures -join ', ')) -ForegroundColor Red
    }
    else {
        Write-Host '[+] All toolchain components removed (or were already absent).' -ForegroundColor Green
    }

    if ($script:DebugMode -and -not $CI) {
        Write-Host ''
        Write-Host '[debug] Leaving window open. Press Enter to close...' -ForegroundColor DarkGray
        [void](Read-Host)
    }
    else {
        Write-Host ''
        Write-Host 'Closing this window...' -ForegroundColor Green
        Start-Sleep -Seconds 2
    }
    exit $(if ($script:Failures.Count -gt 0) { 1 } else { 0 })
}

# ---- 1. Ensure Chocolatey -------------------------------------------
Write-Info 'Package manager'
Write-StatusLine -Component 'Chocolatey' -Status 'checking...'
if (Get-Command choco -ErrorAction SilentlyContinue) {
    $cv = (& choco --version 2>&1 | Select-Object -First 1)
    Write-StatusLine -Component 'Chocolatey' -Status ("already installed  {0}" -f $cv) -Kind ok -Final
}
else {
    $installCmd = "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    $code = Invoke-Managed -FilePath 'powershell' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$installCmd) `
                           -Component 'Chocolatey' -Status 'installing...' `
                           -Detailer { param($l) if ($l -match 'Downloading|Extracting|Installing') { ($l.Trim()) + '...' } else { $null } }
    Update-SessionPath
    if ($code -ne 0 -or -not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-StatusLine -Component 'Chocolatey' -Status 'install failed' -Kind fail -Final
        Fail 'Chocolatey installation did not complete. Open a new Administrator PowerShell and re-run setupc.ps1.'
    }
    $cv = (& choco --version 2>&1 | Select-Object -First 1)
    Write-StatusLine -Component 'Chocolatey' -Status ("installed  {0}" -f $cv) -Kind ok -Final
}

# ---- 2 & 3. Install + verify each package from packages.config -------
Write-Info 'Toolchain (from packages.config)'
if ($usingLocalPkg) { Write-Warn2 "Using local packages.config next to setupc.ps1 (troubleshooting): $PackagesFile" }

foreach ($id in $ids) {
    $m = $Meta[$id.ToLower()]
    if ($m) {
        Install-Component -ChocoId $id -Label $m.Label -VerifyCmds $m.Cmds -VerifyArg $m.Arg -ExtraCmds $m.Extra | Out-Null
    }
    else {
        # Unknown package: install and verify via choco's own inventory.
        Install-Component -ChocoId $id -Label $id -VerifyCmds @($id) | Out-Null
    }
}

# MSYS2 itself is just the base pacman environment - the actual MinGW-w64
# compiler is a follow-up pacman install, not a Chocolatey package. Only
# meaningful if packages.config actually asked for msys2 above.
if ($ids -contains 'msys2') {
    Install-MinGWToolchain | Out-Null
}

# ---- 4. Result summary ------------------------------------------------
Write-Info 'Summary'
$repoName  = Split-Path -Leaf $RepoRoot
$readmeRel = Join-Path $repoName 'README.md'
$success   = ($script:Failures.Count -eq 0)

if ($success) {
    Write-Host '[+] SUCCESS: all components installed and verified.' -ForegroundColor Green
}
else {
    Write-Host ("[x] FAILURE: the following components did not verify: {0}" -f ($script:Failures -join ', ')) -ForegroundColor Red
    Write-Host 'A reboot may be needed for PATH changes to take effect; re-run setupc.ps1 afterwards.' -ForegroundColor Yellow
    if (-not $script:DebugMode) { Write-Host 'Re-run with -Debug for full troubleshooting detail.' -ForegroundColor Yellow }
}

# ---- 5. Open README (unless -CI), then build the project --------------
# -CI is fully hands-off: never opens an editor.
if (-not $CI) {
    Update-SessionPath
    if (Test-Path $ReadmePath) {
        $codeExe = Find-VSCodeExe
        if ($codeExe) {
            Write-Host ''
            Write-Host 'Opening the project in VS Code (full screen)...' -ForegroundColor Green
            Open-VSCodeFullScreen -CodeExe $codeExe -RepoRoot $RepoRoot -ReadmePath $ReadmePath
        }
        else {
            Write-Warn2 "VS Code was not found on PATH or in common install locations. README.md was NOT opened automatically."
            Write-Warn2 "Open it manually in VS Code: $ReadmePath"
        }
    }
    else { Write-Warn2 "No README.md found at '$ReadmePath'." }
}

# Build the project - only if the toolchain came up clean, and only if this
# checkout actually has a CMake preset (keeps this generic rather than
# assuming every repo that ever uses these scripts is this exact project).
$buildOk = $true
$presetsFile = Join-Path $RepoRoot 'CMakePresets.json'
if ($success -and (Test-Path $presetsFile)) {
    Write-Info 'Building the project'
    Push-Location -LiteralPath $RepoRoot
    try {
        Write-Host '[*] cmake --preset debug' -ForegroundColor Yellow
        cmake --preset debug
        if ($LASTEXITCODE -eq 0) {
            Write-Host '[*] cmake --build --preset debug-build' -ForegroundColor Yellow
            cmake --build --preset debug-build
            $buildOk = ($LASTEXITCODE -eq 0)
        }
        else {
            $buildOk = $false
            Write-Warn2 "cmake --preset debug failed (exit $LASTEXITCODE) - skipping build."
        }
    }
    finally {
        Pop-Location
    }
}

if ($CI) {
    exit $(if ($success -and $buildOk) { 0 } else { 1 })
}

# Interactive runs: leave this window open so the build output (and this
# session) stays available to keep working in - no forced close, no wait.
Write-Host ''
if ($success -and $buildOk) { Write-Host 'Setup complete.' -ForegroundColor Green }
else { Write-Host 'Setup finished with issues - see above.' -ForegroundColor Yellow }
Write-Host 'This window will remain open.' -ForegroundColor Green

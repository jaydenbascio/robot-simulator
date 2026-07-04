# ==============================================================================
# Setup script for Windows developers
# ==============================================================================

param (
    [switch]$CI
)

$ErrorActionPreference = "Inquire"

$ScriptErrorCount = 0

# ------------------------------------------------------------------------------
# 0. Ensure Admin Privileges
# ------------------------------------------------------------------------------
# Pass the -CI flag forward if we need to elevate privileges
$CIArg = if ($CI) { "-CI" } else { "" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script requires Administrator privileges to install Visual Studio components." -ForegroundColor Yellow
    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    $Proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $CIArg" -Verb RunAs -Wait -PassThru
    exit $Proc.ExitCode
}

# Ensure working directory is the project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path # Path of this script (should be under scripts folder)
$ProjectRoot = Resolve-Path "$ScriptDir\.."                  # Go to project root directory (outside of scripts)
Set-Location $ProjectRoot

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "   Setting up C++ Simulator Workspace    " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Query Phase (After this the user can get a coffee if they want)
# ------------------------------------------------------------------------------

# --- 1.1 Git presence check ---
$GitInstalled = $false
$GitPath = Get-Command git -ErrorAction SilentlyContinue
if ($GitPath) {
    $GitInstalled = $true # Git is already installed
} else {
    # Check typical Windows git installations if not present in the system PATH yet
    $TypicalGitPaths = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles(x86)\Git\cmd\git.exe",
        "$env:LocalAppData\Programs\Git\cmd\git.exe"
    )
    foreach ($Path in $TypicalGitPaths) {
        if (Test-Path $Path) {
            $GitInstalled = $true
            break
        }
    }
}

# If Git is missing, handle prompting or CI fallback
$InstallGit = $false
if (-not $GitInstalled) {
    Write-Host "Git was not detected on your system." -ForegroundColor Yellow
    if ($CI) {
        Write-Host "[CI Mode] Defaulting to automatically installing Git via winget." -ForegroundColor Cyan
        $InstallGit = $true
    } else {
        $Response = Read-Host "Would you like to automatically install Git via winget? (y/n)"
        if ($Response -eq 'y' -or $Response -eq 'Y') {
            $InstallGit = $true
        } else {
            Write-Host "[WARNING] Git is required to clone and bootstrap vcpkg. Continuing without installing..." -ForegroundColor Yellow
        }
    }
}

# --- 1.2 Parse components from .vsconfig ---
$VsConfigFile = Join-Path $ProjectRoot ".vsconfig"
$RequiredComponents = @()
if (Test-Path $VsConfigFile) {
    try {
        $VsConfig = Get-Content $VsConfigFile -Raw | ConvertFrom-Json
        if ($VsConfig.components) {
            $RequiredComponents = $VsConfig.components
        }
    } catch {
        Write-Host "Warning: Could not parse .vsconfig" -ForegroundColor Yellow
    }
}

# --- 1.3 Scan for existing Visual Studio installations ---
$VsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$LocalInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
$Installations = @()
$SatisfyingDirs = @()

if (Test-Path $VsWherePath) {
    # Get all installations using vswhere.exe (including build tools and prereleases)
    $VswhereOutput = & $VsWherePath -prerelease -products * -format json | ConvertFrom-Json
    if ($VswhereOutput) {
        $Installations = $VswhereOutput
    }
    
    # Filter which installations satisfy all .vsconfig requirements
    if ($RequiredComponents.Count -gt 0) {
        $RequiresArgs = @("-prerelease", "-products", "*")
        foreach ($Comp in $RequiredComponents) {
            $RequiresArgs += "-requires"
            $RequiresArgs += $Comp
        }
        $RequiresArgs += @("-property", "installationPath")
        $SatisfyingDirs = & $VsWherePath $RequiresArgs
    }
}

# --- 1.4 Present Visual Studio menu to user / CI Fallback ---
$VSSelectionAction = "Skip" # Default is to skip
$SelectedVSPath = $null

if ($Installations.Count -gt 0) {
    Write-Host "Checking for Visual Studio installations..." -ForegroundColor Yellow
    Write-Host "The following Visual Studio installations were found:" -ForegroundColor Cyan
    
    $Options = @()
    $BestCIIndex = 1
    $FoundPerfectMatch = $false

    for ($i = 0; $i -lt $Installations.Count; $i++) {
        $Inst = $Installations[$i]
        $Path = $Inst.installationPath
        $DisplayName = $Inst.displayName
        $Version = $Inst.installationVersion
        
        # Check if this installation path is listed in the satisfying installations
        $IsSatisfied = $false
        if ($SatisfyingDirs) {
            foreach ($SatDir in $SatisfyingDirs) {
                if ($SatDir.Trim().ToLower() -eq $Path.Trim().ToLower()) {
                    $IsSatisfied = $true
                    break
                }
            }
        }
        
        $StatusText = ""
        $ForegroundColor = "Yellow"
        if ($IsSatisfied) {
            $StatusText = "[Satisfies .vsconfig]"
            $ForegroundColor = "Green"
            if (-not $FoundPerfectMatch) {
                $BestCIIndex = $i + 1 # Prefer one that already works perfectly in CI
                $FoundPerfectMatch = $true
            }
        } else {
            $StatusText = "[Does NOT satisfy .vsconfig (will add missing components during setup)]"
            $ForegroundColor = "Yellow"
        }
        
        Write-Host "  [$($i + 1)] $DisplayName ($Version) - Path: $Path" -ForegroundColor $ForegroundColor
        Write-Host "      $StatusText" -ForegroundColor $ForegroundColor
        
        $Options += @{
            Index = $i + 1
            Type = "Existing"
            Path = $Path
            IsSatisfied = $IsSatisfied
            DisplayName = $DisplayName
        }
    }
    
    # Install new option
    $NewOptionNum = $Installations.Count + 1
    Write-Host "  [$NewOptionNum] Install/Configure Visual Studio 2022 Build Tools anew" -ForegroundColor Cyan
    $Options += @{
        Index = $NewOptionNum
        Type = "New"
        Path = $null
        IsSatisfied = $false
        DisplayName = "Visual Studio 2022 Build Tools"
    }
    
    # Skip option
    $SkipOptionNum = $Installations.Count + 2
    Write-Host "  [$SkipOptionNum] Skip Visual Studio configuration" -ForegroundColor Gray
    $Options += @{
        Index = $SkipOptionNum
        Type = "Skip"
        Path = $null
        IsSatisfied = $false
        DisplayName = "Skip"
    }
    
    # Get what option the user wants (or auto-select in CI)
    $SelectionInt = 0
    if ($CI) {
        $SelectionInt = $BestCIIndex
        Write-Host "[CI Mode] Auto-selecting option [$SelectionInt] ($($Options[$SelectionInt - 1].DisplayName))" -ForegroundColor Cyan
        $Sel = $Options[$SelectionInt - 1]
        if ($Sel.IsSatisfied) { $VSSelectionAction = "UseExisting" } else { $VSSelectionAction = "ModifyExisting" }
        $SelectedVSPath = $Sel.Path
    } else {
        while ($true) {
            $SelectionStr = Read-Host "Select an option (1-$SkipOptionNum)"
            if ([int]::TryParse($SelectionStr, [ref]$SelectionInt) -and $SelectionInt -ge 1 -and $SelectionInt -le $Options.Count) {
                $Sel = $Options[$SelectionInt - 1]
                if ($Sel.Type -eq "New") {
                    $VSSelectionAction = "InstallNew"
                } elseif ($Sel.Type -eq "Skip") {
                    $VSSelectionAction = "Skip"
                } else {
                    if ($Sel.IsSatisfied) {
                        $VSSelectionAction = "UseExisting"
                    } else {
                        $VSSelectionAction = "ModifyExisting"
                    }
                    $SelectedVSPath = $Sel.Path
                }
                break
            }
            Write-Host "Invalid selection. Please enter a number between 1 and $SkipOptionNum." -ForegroundColor Red
        }
    }
} else {
    Write-Host "No existing Visual Studio installations were detected." -ForegroundColor Yellow
    if ($CI) {
        Write-Host "[CI Mode] Auto-selecting to install fresh Visual Studio 2022 Build Tools." -ForegroundColor Cyan
        $VSSelectionAction = "InstallNew"
    } else {
        $Response = Read-Host "Would you like to install/configure Visual Studio 2022 Build Tools now? (y/n)"
        if ($Response -eq 'y' -or $Response -eq 'Y') {
            $VSSelectionAction = "InstallNew"
        } else {
            $VSSelectionAction = "Skip"
            Write-Host "Skipping Visual Studio configuration. You will need to manually configure compiler settings." -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------------------------
# 2. Execution Phase (Hands-free, user can go have a coffee if they want it)
# ------------------------------------------------------------------------------
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "   Executing workspace configuration...  " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# --- 2.1 Git Installation (via winget) ---
if ($InstallGit) {
    Write-Host "Installing Git via winget..." -ForegroundColor Cyan
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Git.Git --accept-package-agreements --accept-source-agreements --exact
    } else {
        Write-Host "[ERROR] winget is not available on this system. Are you even using Windows?" -ForegroundColor Red
        if (-not $CI) { pause }
        exit 1
    }
    
    # Refresh PATH for the current session to detect Git immediately
    $TypicalGitPaths = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:ProgramFiles(x86)\Git\cmd\git.exe",
        "$env:LocalAppData\Programs\Git\cmd\git.exe"
    )
    foreach ($Path in $TypicalGitPaths) {
        if (Test-Path $Path) {
            $env:Path = "$(Split-Path $Path);" + $env:Path
            Write-Host "Git path configured: $Path" -ForegroundColor Green
            break
        }
    }
}

# --- 2.2 Visual Studio Setup ---
$FinalVSPath = $null

if ($VSSelectionAction -eq "UseExisting") {
    Write-Host "Using selected Visual Studio installation at: $SelectedVSPath" -ForegroundColor Green
    $FinalVSPath = $SelectedVSPath
} 
elseif ($VSSelectionAction -eq "ModifyExisting") {
    Write-Host "Modifying existing Visual Studio installation to satisfy .vsconfig components..." -ForegroundColor Cyan
    if (Test-Path $LocalInstallerPath) {
        Write-Host "Running VS Installer modify on path: $SelectedVSPath" -ForegroundColor Yellow
        $VsArgs = "modify --installPath `"$SelectedVSPath`" --passive --norestart --config `"$VsConfigFile`""
        $Proc = Start-Process $LocalInstallerPath -ArgumentList $VsArgs -Wait -NoNewWindow -PassThru
        if ($Proc.ExitCode -ne 0) {
            Write-Host "Warning: VS Installer returned non-zero exit code: $($Proc.ExitCode)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[ERROR] Visual Studio installer not found at $LocalInstallerPath. Could not modify installation." -ForegroundColor Red
        $ScriptErrorCount += 1
    }
    $FinalVSPath = $SelectedVSPath
} 
elseif ($VSSelectionAction -eq "InstallNew") {
    Write-Host "Installing fresh Visual Studio 2022 Build Tools via bootstrapper..." -ForegroundColor Cyan
    
    Write-Host "Downloading official Visual Studio 2022 Build Tools bootstrapper..." -ForegroundColor Yellow
    $BootstrapperPath = Join-Path $env:TEMP "vs_buildtools.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $BootstrapperPath
    
    Write-Host "Running Visual Studio Bootstrapper with your .vsconfig..." -ForegroundColor Yellow
    $Proc = Start-Process $BootstrapperPath -ArgumentList "--productId Microsoft.VisualStudio.Product.BuildTools --passive --norestart --wait --config `"$VsConfigFile`"" -Wait -PassThru
    Remove-Item $BootstrapperPath -ErrorAction SilentlyContinue
    
    if (Test-Path $VsWherePath) {
        $FinalVSPath = & $VsWherePath -latest -products * -property installationPath
    }
    if (-not $FinalVSPath) {
        $FinalVSPath = "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools"
        if (-not (Test-Path $FinalVSPath)) {
            $FinalVSPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools"
        }
    }
}

# --- 2.3 Verification of VS Components ---
if ($VSSelectionAction -ne "Skip" -and $FinalVSPath) {
    Write-Host "Verifying component registration for: $FinalVSPath" -ForegroundColor Yellow
    if (Test-Path $VsWherePath) {
        $RequiresArgs = @("-prerelease", "-products", "*")
        foreach ($Comp in $RequiredComponents) {
            $RequiresArgs += "-requires"
            $RequiresArgs += $Comp
        }
        $RequiresArgs += @("-property", "installationPath")
        
        $SatisfyingDirs = & $VsWherePath $RequiresArgs
        
        $IsVerified = $false
        if ($SatisfyingDirs) {
            foreach ($SatDir in $SatisfyingDirs) {
                if ($SatDir.Trim().ToLower() -eq $FinalVSPath.Trim().ToLower()) {
                    $IsVerified = $true
                    break
                }
            }
        }
        
        if ($IsVerified) {
            Write-Host "Successfully verified MSVC C++ Build Tools!" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Workloads from .vsconfig could not be verified for path: $FinalVSPath" -ForegroundColor Red
            Write-Host "Please contact the IT Help Desk, or submit an Issue to GitHub." -ForegroundColor Red
            $ScriptErrorCount += 1
        }
    } else {
        Write-Host "vswhere not found. Could not verify components." -ForegroundColor Yellow
    }
}

# --- 2.4 Set up vcpkg ---
$VcpkgPath = Join-Path $ProjectRoot "vcpkg"
$VCPKG_ROOT = $VcpkgPath
$BootstrapScript = Join-Path $VcpkgPath "bootstrap-vcpkg.bat"
Write-Host "Bootstrapping vcpkg..." -ForegroundColor Yellow
& $BootstrapScript

# --- 2.5 Run Manifest Mode Installation ---
$VcpkgExe = Join-Path $VcpkgPath "vcpkg.exe"
$VcpkgJsonPath = Join-Path $ProjectRoot "vcpkg.json"

if (Test-Path $VcpkgJsonPath) {
    Write-Host "vcpkg.json detected. Running installation in Manifest Mode..." -ForegroundColor Cyan

    & $VcpkgExe install --triplet x64-windows --x-manifest-root="$ProjectRoot"

    $NinjaDir = Split-Path -Path (& $VcpkgExe fetch ninja)
    if (Test-Path (Join-Path $NinjaDir "ninja.exe")) {
        Write-Host "Ninja verified from manifest at: $NinjaDir" -ForegroundColor Green
    } else {
         Write-Host "[ERROR] Ninja executable not found in manifest tools directory." -ForegroundColor Red
         $ScriptErrorCount += 1
    }
} else {
    Write-Host "[ERROR] vcpkg.json missing from project root. Cannot run manifest mode installation." -ForegroundColor Red
    $ScriptErrorCount += 1
}

# --- 2.6 Save Local Environment Configuration ---
$VsConfigPs1 = Join-Path $ScriptDir "run-env.ps1"
$CurrentDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$ConfigLines = @(
    "# ==============================================================================",
    "# AUTOGENERATED BY SETUP.PS1 SO DO NOT TOUCH OR IT WILL BREAK.",
    "# Generated on: $CurrentDate",
    "# ==============================================================================",
    ""
)

if ($FinalVSPath) {
    $ConfigLines += "`$VS_INSTALL_DIR = `"$FinalVSPath`""
    $ConfigLines += '  $VcvarsBat = Join-Path $VS_INSTALL_DIR "VC\Auxiliary\Build\vcvarsall.bat"'
    $ConfigLines += ""
    $ConfigLines += 'if (-not (Test-Path $VS_INSTALL_DIR)) {'
    $ConfigLines += '    Write-Host "[ERROR] Visual Studio directory not found at: $VS_INSTALL_DIR" -ForegroundColor Red'
    $ConfigLines += '    Write-Host "Please run setup.ps1 again." -ForegroundColor Yellow'
    $ConfigLines += '    exit 1'
    $ConfigLines += '}'
    $ConfigLines += 'if (-not (Test-Path $VcvarsBat)) {'
    $ConfigLines += '    Write-Host "[ERROR] vcvarsall.bat not found at $VcvarsBat" -ForegroundColor Red'
    $ConfigLines += '    exit 1'
    $ConfigLines += '}'
    $ConfigLines += ""
    $ConfigLines += '# Load MSVC compiler environment variables into PowerShell'
    $ConfigLines += 'Write-Host "Loading MSVC compiler environment..." -ForegroundColor Yellow'
    $ConfigLines += '  $CmdLine = ''"'' + $VcvarsBat + ''" x64 && set'''
    $ConfigLines += '  $Vars = cmd.exe /c $CmdLine'
    $ConfigLines += 'foreach ($Var in $Vars) {`'
    $ConfigLines += '    if ($Var -match ''^([^=]+)=(.*)$'') {'
    $ConfigLines += '        $Name = $Matches[1]'
    $ConfigLines += '        $Value = $Matches[2]'
    $ConfigLines += '        [System.Environment]::SetEnvironmentVariable($Name, $Value, [System.EnvironmentVariableTarget]::Process)'
    $ConfigLines += '    }'
    $ConfigLines += '}'
}

if ($NinjaDir) {
    $ConfigLines += ""
    $ConfigLines += '# Configure Ninja path'
    $ConfigLines += "`$NINJA_DIR = `"$NinjaDir`""
    $ConfigLines += 'if (Test-Path $NINJA_DIR) {'
    $ConfigLines += '    $env:Path = "$NINJA_DIR;" + $env:Path'
    $ConfigLines += '} else {'
    $ConfigLines += '    Write-Host "[WARNING] Configured Ninja path not found at $NINJA_DIR" -ForegroundColor Yellow'
    $ConfigLines += '}'
}

$ConfigLines += ""
$ConfigLines += '# Customize the prompt to show you are in the wrapper'
$ConfigLines += 'function prompt {'
$ConfigLines += '    "(CMake) $pwd> "'
$ConfigLines += '}'

if ($ConfigLines.Count -gt 0) {
    Set-Content -Path $VsConfigPs1 -Value $ConfigLines -Encoding UTF8
    Write-Host "Saved autogenerated configuration to: $VsConfigPs1" -ForegroundColor Green
}

if ($ScriptErrorCount -gt 0) {
    Write-Host "Script failed with $ScriptErrorCount errors." -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host "        Yey! Setup complete!            " -ForegroundColor Green
    Write-Host " You can now configure and build using CMake presets." -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
}

# Only pause if we are NOT running in CI mode
if (-not $CI) {
    pause
}
# Boxstarter Script
# https://boxstarter.org/weblauncher
# START https://boxstarter.org/package/nr/url?https://raw.githubusercontent.com/gambtho/dotfiles/refs/heads/main/platforms/windows/boxstarter.ps1

function Invoke-NativeOrThrow {
    [CmdletBinding()]
    Param([scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $Command"
    }
}

function removeApp {
    Param ([string]$appName)
    Write-Host "[DEBUG] Attempting to remove app: $appName"
    try {
        Get-AppxPackage $appName -AllUsers | Remove-AppxPackage -ErrorAction Stop
        Get-AppXProvisionedPackage -Online | Where DisplayName -like $appName | Remove-AppxProvisionedPackage -Online -ErrorAction Stop
        Write-Host "[INFO] Successfully removed app: $appName"
    } catch {
        Write-Host "[WARN] Could not remove app: $appName - $_"
    }
}

# Disable User Account Control
Write-Host "[DEBUG] Disabling UAC..."
Disable-UAC

# Step 1: Configure Windows Features and Settings
Write-Host "[DEBUG] Configuring Windows features and settings..."

# Enable Developer Mode (allows symlink creation without UAC elevation)
Write-Host "[DEBUG] Enabling Developer Mode..."
try {
    Invoke-NativeOrThrow { reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /d 1 /f /v "AllowDevelopmentWithoutDevLicense" }
    Write-Host "[INFO] Developer Mode enabled."
} catch {
    Write-Host "[ERROR] Failed to enable Developer Mode: $_"
}

# File Explorer Settings
try {
    Set-WindowsExplorerOptions -EnableShowHiddenFilesFoldersDrives -EnableShowProtectedOSFiles -EnableShowFileExtensions
    Write-Host "[INFO] Set Windows Explorer options successfully."
    Set-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name NavPaneExpandToCurrentFolder -Value 1
    Set-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name NavPaneShowAllFolders -Value 1
    Set-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name LaunchTo -Value 1
    Set-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name MMTaskbarMode -Value 2
    Write-Host "[INFO] Configured File Explorer settings successfully."
} catch {
    Write-Host "[ERROR] Failed to configure File Explorer settings: $_"
}

# Step 2: Remove Default Windows Applications
Write-Host "[DEBUG] Removing unnecessary default applications..."
$applicationList = @(
    "Microsoft.BingFinance", "Microsoft.BingNews", "Microsoft.BingSports",
    "Microsoft.BingWeather", "Microsoft.GetHelp", "Microsoft.Getstarted",
    "Microsoft.WindowsMaps", "Microsoft.Messaging", "*Minecraft*",
    "Microsoft.MicrosoftOfficeHub", "Microsoft.OneConnect",
    "Microsoft.WindowsSoundRecorder", "*Solitaire*", "Microsoft.MicrosoftStickyNotes",
    "Microsoft.Office.Sway", "Microsoft.XboxApp", "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxGameOverlay", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo",
    "Microsoft.NetworkSpeedTest", "Microsoft.Print3D",
    "Microsoft.People*", "Microsoft.Microsoft3DViewer",
    "*Skype*", "*Autodesk*", "*BubbleWitch*", "king.com*", "G5*",
    "*Facebook*", "*Keeper*", "*Netflix*", "*Twitter*", "*Plex*",
    "*.Duolingo-LearnLanguagesforFree", "*.EclipseManager",
    "ActiproSoftwareLLC.562882FEEB491", "*.AdobePhotoshopExpress"
)
foreach ($app in $applicationList) {
    removeApp $app
}

# Step 3: Install Developer Tools via winget
Write-Host "[DEBUG] Installing developer tools via winget..."
$apps = @(
    @{name = "Git.Git"},
    @{name = "GnuPG.Gpg4win"},
    @{name = "Google.Chrome"},
    @{name = "JetBrains.Toolbox"},
    @{name = "Microsoft.dotnet"},
    @{name = "Microsoft.PowerShell"},
    @{name = "Microsoft.PowerToys"},
    @{name = "Microsoft.VisualStudioCode"},
    @{name = "Microsoft.WindowsTerminal"},
    @{name = "AgileBits.1Password"},
    @{name = "Doist.Todoist"},
    @{name = "Microsoft.AzureCLI"}
)
foreach ($app in $apps) {
    Write-Host "[DEBUG] Checking if app is installed: $($app.name)"
    $listApp = winget list --exact -q $app.name
    if (![String]::Join("", $listApp).Contains($app.name)) {
        Write-Host "[INFO] Installing: $($app.name)"
        try {
            Invoke-NativeOrThrow { winget install -e --accept-source-agreements --accept-package-agreements --id $app.name }
            Write-Host "[INFO] Successfully installed: $($app.name)"
        } catch {
            Write-Host "[ERROR] Failed to install: $($app.name) - $_"
        }
    } else {
        Write-Host "[INFO] Skipping: $($app.name) (already installed)"
    }
}

# Install Nerd Fonts (Hack) via choco — not available in winget
Write-Host "[DEBUG] Installing Nerd Fonts via chocolatey..."
try {
    Invoke-NativeOrThrow { choco install -y nerd-fonts-hack }
    Write-Host "[INFO] Nerd Fonts installed."
} catch {
    Write-Host "[ERROR] Failed to install Nerd Fonts: $_"
}

# Step 4: Install Az PowerShell module
Write-Host "[DEBUG] Installing Az PowerShell module..."
try {
    Install-Module -Force Az
    Update-SessionEnvironment
    Write-Host "[INFO] Az module installed."
} catch {
    Write-Host "[ERROR] Failed to install Az module: $_"
}

# Step 5: Enable WSL 2
Write-Host "[DEBUG] Installing WSL 2..."
try {
    Invoke-NativeOrThrow { wsl --install }
    Invoke-NativeOrThrow { wsl --set-default-version 2 }
    Write-Host "[INFO] WSL 2 installed and set as default. A reboot is required to complete setup."
} catch {
    Write-Host "[ERROR] Failed to install WSL: $_"
}

# Step 6: Configure Windows Terminal to default to WSL
Write-Host "[DEBUG] Configuring Windows Terminal default profile..."
try {
    $wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (Test-Path $wtSettingsPath) {
        $wtSettings = Get-Content -Raw $wtSettingsPath | ConvertFrom-Json
        # Find the WSL profile GUID and set as default
        $wslProfile = $wtSettings.profiles.list | Where-Object { $_.name -like "*Ubuntu*" -or $_.source -like "*wsl*" } | Select-Object -First 1
        if ($wslProfile) {
            $wtSettings.defaultProfile = $wslProfile.guid
            $wtSettings | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath
            Write-Host "[INFO] Windows Terminal default profile set to: $($wslProfile.name)"
        } else {
            Write-Host "[WARN] No WSL profile found in Windows Terminal settings. Set the default profile manually."
        }
    } else {
        Write-Host "[WARN] Windows Terminal settings not found at expected path. Launch it once first, then re-run this step."
    }
} catch {
    Write-Host "[ERROR] Failed to configure Windows Terminal: $_"
}

# Step 7: Re-enable Critical Settings
Write-Host "[DEBUG] Re-enabling critical settings..."
try {
    Enable-UAC
    Enable-MicrosoftUpdate
    Install-WindowsUpdate -acceptEula
    Write-Host "[INFO] Re-enabled critical settings successfully."
} catch {
    Write-Host "[ERROR] Failed to re-enable critical settings: $_"
}

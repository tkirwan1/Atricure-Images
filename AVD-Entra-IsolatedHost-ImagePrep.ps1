# AVD-Entra-IsolatedHost-ImagePrep.ps1
# Azure VM Image Builder customization for a single-user, Microsoft Entra joined
# Azure Virtual Desktop session host used for isolated file transfer.
#
# Intended visible customizer order:
#   1. Windows Update
#   2. Windows Restart
#   3. This PowerShell script (run as SYSTEM and elevated)
#   4. Windows Restart
#
# This script intentionally does not configure FSLogix, domain join, Microsoft
# Entra join, Intune enrollment, OneDrive policy, or the partner VPN client.
# Those items are applied at deployment time or through Intune.

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workFolder = 'C:\AVDImagePrep'
$logFile = Join-Path $workFolder 'ImagePrep.log'
New-Item -Path $workFolder -ItemType Directory -Force | Out-Null

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)

    $line = '{0:u} {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Set-DwordValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty `
        -Path $Path `
        -Name $Name `
        -PropertyType DWord `
        -Value $Value `
        -Force | Out-Null
}

function Assert-AzureAgentService {
    param([Parameter(Mandatory)][string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "Required Azure VM Agent service '$Name' is missing."
    }

    Set-Service -Name $Name -StartupType Automatic

    if ($service.Status -ne 'Running') {
        Start-Service -Name $Name
    }

    $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
    Write-Log "Verified Azure service '$Name' is installed and running."
}

function Remove-OptionalAppxPackage {
    param([Parameter(Mandatory)][string]$PackageName)

    $matched = $false

    Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue |
        ForEach-Object {
            $matched = $true
            try {
                Remove-AppxPackage `
                    -Package $_.PackageFullName `
                    -AllUsers `
                    -ErrorAction Stop
                Write-Log "Removed installed Appx package '$($_.Name)'."
            }
            catch {
                Write-Log "Installed Appx removal skipped for '$($_.Name)': $($_.Exception.Message)"
            }
        }

    Get-AppxProvisionedPackage -Online |
        Where-Object {
            $_.DisplayName -eq $PackageName -or
            $_.DisplayName -like "$PackageName*"
        } |
        ForEach-Object {
            $matched = $true
            try {
                Remove-AppxProvisionedPackage `
                    -Online `
                    -PackageName $_.PackageName `
                    -AllUsers `
                    -ErrorAction Stop | Out-Null
                Write-Log "Removed provisioned Appx package '$($_.DisplayName)'."
            }
            catch {
                Write-Log "Provisioned Appx removal skipped for '$($_.DisplayName)': $($_.Exception.Message)"
            }
        }

    if (-not $matched) {
        Write-Log "Optional Appx package '$PackageName' was not present."
    }
}

Write-Log 'Starting isolated Entra-joined AVD image preparation.'
Write-Log "Operating system: $((Get-CimInstance Win32_OperatingSystem).Caption)"

# Azure mounts provisioning media through the virtual DVD drive when a VM is
# created from a generalized image.
Set-DwordValue `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom' `
    -Name 'Start' `
    -Value 1
Write-Log 'Enabled the CD/DVD-ROM service for Azure OOBE provisioning.'

# Fail the build rather than capture an image without a working Azure VM Agent.
Assert-AzureAgentService -Name 'RdAgent'
Assert-AzureAgentService -Name 'WindowsAzureGuestAgent'

$telemetryService = Get-Service -Name 'WindowsAzureTelemetryService' -ErrorAction SilentlyContinue
if ($telemetryService) {
    Write-Log 'WindowsAzureTelemetryService is present.'
}
else {
    Write-Log 'WindowsAzureTelemetryService is absent and treated as optional.'
}

# Small, low-risk AVD setting.
Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
    -Name 'fEnableTimeZoneRedirection' `
    -Value 1
Write-Log 'Enabled AVD time-zone redirection.'

# Disable consumer suggestions and taskbar widgets without removing shell
# components that Windows, Entra sign-in, or OOBE may require.
Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
    -Name 'DisableWindowsConsumerFeatures' `
    -Value 1

Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
    -Name 'DisableConsumerAccountStateContent' `
    -Value 1

Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' `
    -Name 'AllowNewsAndInterests' `
    -Value 0
Write-Log 'Disabled Windows consumer suggestions and widgets.'

# This list is based primarily on the package-removal set that already completed
# successfully against the same Windows 11 25H2 source image in the prior AIB
# build. A few newer optional apps are included as best-effort removals.
#
# Deliberately preserved for reliability and supportability:
#   Microsoft Edge and WebView2
#   File Explorer, Start, Search, Settings, OOBE, and Entra broker components
#   OneDrive
#   Microsoft Store and App Installer
#   Windows Security
#   Notepad, Calculator, and Windows Terminal
#   Media/image codecs used by Edge and File Explorer
$optionalPackages = @(
    'Clipchamp.Clipchamp',
    'Microsoft.549981C3F5F10',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GamingApp',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.MSPaint',
    'Microsoft.Office.OneNote',
    'Microsoft.OutlookForWindows',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.ScreenSketch',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.Windows.DevHome',
    'Microsoft.Windows.Photos',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsCommunicationsApps',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'MSTeams'
)

foreach ($package in $optionalPackages) {
    Remove-OptionalAppxPackage -PackageName $package
}

# Confirm the three core capabilities requested for this image remain available.
if (-not (Test-Path "$env:WINDIR\explorer.exe")) {
    throw 'File Explorer is missing.'
}

$edgePaths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)

if (-not ($edgePaths | Where-Object { Test-Path -LiteralPath $_ })) {
    throw 'Microsoft Edge is missing.'
}

$oneDrivePaths = @(
    "$env:WINDIR\SysWOW64\OneDriveSetup.exe",
    "$env:WINDIR\System32\OneDriveSetup.exe",
    "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
    "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"
)

if ($oneDrivePaths | Where-Object { Test-Path -LiteralPath $_ }) {
    Write-Log 'Verified OneDrive or its in-box installer is present.'
}
else {
    Write-Log 'WARNING: OneDrive was not found in its common in-box locations. Install it through Intune before user testing.'
}

# Remove only the temporary folder used by this customization. Do not delete
# Windows servicing, Store, or Azure Agent data.
Get-ChildItem -Path $workFolder -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $logFile } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Azure VM Image Builder executes C:\DeprovisioningScript.ps1 after the visible
# customizers. This override treats the telemetry service as optional, verifies
# the required Azure Agent services, enables CD-ROM, and uses VM-aware Sysprep.
$deprovisioningScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Wait-RequiredService {
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$Required = $true,
        [int]$TimeoutSeconds = 300
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue

    if (-not $service) {
        if ($Required) {
            throw "Required service '$Name' is missing."
        }

        Write-Output ">>> Optional service '$Name' is not present."
        return
    }

    Set-Service -Name $Name -StartupType Automatic -ErrorAction SilentlyContinue

    if ($service.Status -ne 'Running') {
        Start-Service -Name $Name -ErrorAction Stop
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $service.Refresh()

        if ($service.Status -eq 'Running') {
            Write-Output ">>> Service '$Name' is running."
            return
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "Service '$Name' did not reach Running state within $TimeoutSeconds seconds."
}

Write-Output '>>> Verifying Azure VM Agent services ...'
Wait-RequiredService -Name 'RdAgent'
Wait-RequiredService -Name 'WindowsAzureGuestAgent'
Wait-RequiredService -Name 'WindowsAzureTelemetryService' -Required $false

New-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom' `
    -Name 'Start' `
    -PropertyType DWord `
    -Value 1 `
    -Force | Out-Null

# Give Windows servicing and the Azure Agent time to settle after the final
# restart before Sysprep starts.
Start-Sleep -Seconds 60

Write-Output '>>> Removing stale Panther and unattended setup data ...'
Remove-Item -LiteralPath "$env:SystemRoot\Panther" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:SystemRoot\System32\Sysprep\unattend.xml" -Force -ErrorAction SilentlyContinue

Write-Output '>>> Starting Sysprep for an Azure VM image ...'
$sysprep = Start-Process `
    -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
    -ArgumentList '/oobe','/generalize','/quiet','/quit','/mode:vm' `
    -Wait `
    -PassThru

if ($sysprep.ExitCode -ne 0) {
    Write-Output '>>> Sysprep failed. Recent setuperr.log entries follow:'
    Get-Content `
        "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log" `
        -Tail 100 `
        -ErrorAction SilentlyContinue

    throw "Sysprep exited with code $($sysprep.ExitCode)."
}

$expectedState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
$deadline = (Get-Date).AddMinutes(20)
$imageState = $null

do {
    $imageState = (Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
        -Name 'ImageState').ImageState

    Write-Output ">>> ImageState: $imageState"

    if ($imageState -eq $expectedState) {
        Write-Output '>>> Sysprep completed successfully.'
        exit 0
    }

    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

Write-Output '>>> Sysprep did not reach the expected image state. Recent logs follow:'
Get-Content `
    "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log" `
    -Tail 100 `
    -ErrorAction SilentlyContinue
Get-Content `
    "$env:SystemRoot\System32\Sysprep\Panther\setupact.log" `
    -Tail 100 `
    -ErrorAction SilentlyContinue

throw "Timed out waiting for image state '$expectedState'. Last state was '$imageState'."
'@

Set-Content `
    -Path 'C:\DeprovisioningScript.ps1' `
    -Value $deprovisioningScript `
    -Encoding UTF8 `
    -Force

Write-Log 'Installed the Azure Image Builder deprovisioning and Sysprep override.'
Write-Log 'Image preparation completed successfully.'

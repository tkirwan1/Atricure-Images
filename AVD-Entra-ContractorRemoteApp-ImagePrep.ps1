# AVD-Entra-ContractorRemoteApp-ImagePrep.ps1
# Azure VM Image Builder customization for a pooled, Microsoft Entra joined
# Azure Virtual Desktop session host used for contractor RemoteApp access.
#
# Intended Custom Image Template order:
#   1. Windows Update
#   2. Windows Restart
#   3. Current Microsoft-provided Teams optimization customization
#   4. This PowerShell script (run as SYSTEM and elevated)
#   5. Windows Restart
#
# This script installs and validates the native Teams and Remote Help clients.
# It intentionally does not configure FSLogix, Microsoft Entra join, Intune
# enrollment, AVD registration, AppLocker, Edge URL policy, or user data.
# Those items are applied at deployment time or through Intune.

[CmdletBinding()]
param(
    [string]$TeamsBootstrapperUri = 'https://go.microsoft.com/fwlink/?clcid=0x409&linkid=2243204',
    [string]$TeamsBootstrapperSha256 = '',
    [string]$TeamsMsixUri = '',
    [string]$TeamsMsixSha256 = '',
    [string]$RemoteHelpInstallerUri = 'https://aka.ms/downloadremotehelp',
    [string]$RemoteHelpInstallerSha256 = '',
    [switch]$SkipTeamsInstall,
    [switch]$SkipRemoteHelpInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

function Assert-FileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        return
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $expected = $ExpectedSha256.Replace(' ', '').ToUpperInvariant()

    if ($actual.ToUpperInvariant() -ne $expected) {
        throw "SHA256 mismatch for '$Path'. Expected '$expected'; actual '$actual'."
    }

    Write-Log "Verified SHA256 for '$Path'."
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ExpectedSha256
    )

    $parent = Split-Path -Path $Destination -Parent
    New-Item -Path $parent -ItemType Directory -Force | Out-Null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Log "Downloading '$Uri' to '$Destination' (attempt $attempt of 3)."
            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $Destination `
                -UseBasicParsing `
                -Headers @{ 'User-Agent' = 'AVD-ImageBuilder' }

            if (-not (Test-Path -LiteralPath $Destination)) {
                throw "Download completed without creating '$Destination'."
            }

            Assert-FileHash `
                -Path $Destination `
                -ExpectedSha256 $ExpectedSha256

            return
        }
        catch {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue

            if ($attempt -eq 3) {
                throw
            }

            Write-Log "Download attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0),
        [Parameter(Mandatory)][string]$DisplayName
    )

    Write-Log "Starting $DisplayName installation."

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -Wait `
        -PassThru

    if ($process.ExitCode -notin $SuccessExitCodes) {
        throw "$DisplayName installer exited with code $($process.ExitCode)."
    }

    Write-Log "$DisplayName installation completed successfully with exit code $($process.ExitCode)."
}

function Assert-TeamsInstalled {
    $installed = Get-AppxPackage `
        -AllUsers `
        -Name 'MSTeams' `
        -ErrorAction SilentlyContinue |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    $provisioned = Get-AppxProvisionedPackage -Online |
        Where-Object { $_.DisplayName -eq 'MSTeams' } |
        Select-Object -First 1

    if (-not $installed -and -not $provisioned) {
        throw 'The MSTeams package is not installed or provisioned.'
    }

    if ($installed) {
        Write-Log "Verified installed Teams package version '$($installed.Version)'."
    }
    else {
        Write-Log "Verified provisioned Teams package '$($provisioned.PackageName)'."
    }
}

function Assert-WebView2Installed {
    $roots = @(
        "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application",
        "$env:ProgramFiles\Microsoft\EdgeWebView\Application"
    )

    $webView2 = Get-ChildItem `
        -Path $roots `
        -Filter 'msedgewebview2.exe' `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $webView2) {
        throw 'Microsoft Edge WebView2 Runtime is missing.'
    }

    Write-Log "Verified WebView2 at '$($webView2.FullName)'."
}

Write-Log 'Starting contractor RemoteApp image preparation.'
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

$telemetryService = Get-Service `
    -Name 'WindowsAzureTelemetryService' `
    -ErrorAction SilentlyContinue

if ($telemetryService) {
    Write-Log 'WindowsAzureTelemetryService is present.'
}
else {
    Write-Log 'WindowsAzureTelemetryService is absent and treated as optional.'
}

# AVD settings that are safe to bake into the generalized image.
Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
    -Name 'fEnableTimeZoneRedirection' `
    -Value 1
Write-Log 'Enabled AVD time-zone redirection.'

Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Microsoft\Teams' `
    -Name 'IsWVDEnvironment' `
    -Value 1
Write-Log 'Configured the Teams AVD environment registry value.'

# Disable consumer suggestions and taskbar widgets without removing shell,
# authentication, WebView2, Store, App Installer, camera, or Teams components.
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

# Deliberately preserved:
#   Microsoft Edge and WebView2
#   Microsoft Store and App Installer
#   MSTeams
#   Windows Camera
#   Windows Security
#   File Explorer, Start, Search, Settings, OOBE, and Entra broker components
#   Notepad, Calculator, Windows Terminal, and required media codecs
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
    'MicrosoftCorporationII.QuickAssist'
)

foreach ($package in $optionalPackages) {
    Remove-OptionalAppxPackage -PackageName $package
}

if (-not $SkipTeamsInstall) {
    $teamsBootstrapper = Join-Path $workFolder 'teamsbootstrapper.exe'

    Invoke-Download `
        -Uri $TeamsBootstrapperUri `
        -Destination $teamsBootstrapper `
        -ExpectedSha256 $TeamsBootstrapperSha256

    if ([string]::IsNullOrWhiteSpace($TeamsMsixUri)) {
        Invoke-Installer `
            -FilePath $teamsBootstrapper `
            -ArgumentList @('-p') `
            -DisplayName 'Microsoft Teams'
    }
    else {
        $teamsMsix = Join-Path $workFolder 'MSTeams-x64.msix'

        Invoke-Download `
            -Uri $TeamsMsixUri `
            -Destination $teamsMsix `
            -ExpectedSha256 $TeamsMsixSha256

        Invoke-Installer `
            -FilePath $teamsBootstrapper `
            -ArgumentList @('-p', '-o', $teamsMsix) `
            -DisplayName 'Microsoft Teams'
    }
}
else {
    Write-Log 'Teams installation was skipped by parameter.'
}

Assert-TeamsInstalled

if (-not $SkipRemoteHelpInstall) {
    $remoteHelpInstaller = Join-Path $workFolder 'remotehelpinstaller.exe'

    Invoke-Download `
        -Uri $RemoteHelpInstallerUri `
        -Destination $remoteHelpInstaller `
        -ExpectedSha256 $RemoteHelpInstallerSha256

    Invoke-Installer `
        -FilePath $remoteHelpInstaller `
        -ArgumentList @('/quiet', 'acceptTerms=1') `
        -SuccessExitCodes @(0, 1641, 3010) `
        -DisplayName 'Microsoft Remote Help'
}
else {
    Write-Log 'Remote Help installation was skipped by parameter.'
}

$remoteHelpPath = "$env:ProgramFiles\Remote Help\RemoteHelp.exe"
if (-not (Test-Path -LiteralPath $remoteHelpPath)) {
    throw "Remote Help is missing from '$remoteHelpPath'."
}

$remoteHelpVersion = (Get-Item -LiteralPath $remoteHelpPath).VersionInfo.FileVersion
Write-Log "Verified Remote Help version '$remoteHelpVersion'."

$explorerPath = Join-Path $env:WINDIR 'explorer.exe'
if (-not (Test-Path -LiteralPath $explorerPath)) {
    throw "The Windows shell is missing from '$explorerPath'."
}

Write-Log "Verified the Windows shell at '$explorerPath'."

$edgePaths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)

$edgePath = $edgePaths |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

if (-not $edgePath) {
    throw 'Microsoft Edge is missing.'
}

Write-Log "Verified Microsoft Edge at '$edgePath'."
Assert-WebView2Installed

# Remove downloaded installers while preserving the build log.
Get-ChildItem -Path $workFolder -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $logFile } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Azure VM Image Builder executes C:\DeprovisioningScript.ps1 after the visible
# customizers. This override treats the telemetry service as optional, verifies
# required Azure Agent services, enables CD-ROM, and uses VM-aware Sysprep.
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

# Allow servicing and Azure Agent activity to settle before Sysprep.
Start-Sleep -Seconds 60

Write-Output '>>> Removing stale Panther and unattended setup data ...'
Remove-Item `
    -LiteralPath "$env:SystemRoot\Panther" `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue
Remove-Item `
    -LiteralPath "$env:SystemRoot\System32\Sysprep\unattend.xml" `
    -Force `
    -ErrorAction SilentlyContinue

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
Write-Log 'Contractor RemoteApp image preparation completed successfully.'

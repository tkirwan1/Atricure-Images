# AVD-Entra-EmployeeDesktop-ImagePrep.ps1
# Conservative Azure VM Image Builder customization for a pooled,
# Microsoft Entra joined Azure Virtual Desktop employee desktop.
#
# Intended Custom Image Template order:
#   1. Apply Windows Updates
#   2. Remove Appx packages (Microsoft-provided built-in customization,
#      using only the approved conservative package list)
#   3. Install Teams with optimizations
#   4. This PowerShell script (run as SYSTEM and elevated)
#   5. Windows Restart
#
# Recommended source image:
#   Windows 11 Enterprise multi-session, Version 25H2 + Microsoft 365 Apps
#
# The source image supplies Microsoft 365 Apps and FSLogix. The preceding
# Microsoft customization supplies Teams and its AVD optimization components.
# This script validates those components, enables Office shared-computer
# activation, applies a few low-risk machine settings, and installs a bounded
# Azure Image Builder Sysprep override.
#
# This script deliberately does not configure:
#   - Microsoft Entra join or Intune enrollment
#   - AVD host-pool registration
#   - FSLogix Enabled, VHDLocations, Cloud Cache, or storage authentication
#   - Organization-specific Office, OneDrive, Edge, Defender, or security policy
# Those settings belong at session-host deployment time or in Intune.

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workFolder = 'C:\AVDImagePrep'
$logFile = Join-Path $workFolder 'EmployeeDesktop-ImagePrep.log'
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

function Set-StringValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty `
        -Path $Path `
        -Name $Name `
        -PropertyType String `
        -Value $Value `
        -Force | Out-Null
}

function Assert-ServicePresent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$Required = $true,
        [bool]$StartService = $true
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue

    if (-not $service) {
        if ($Required) {
            throw "Required service '$Name' is missing."
        }

        Write-Log "Optional service '$Name' is not present."
        return
    }

    if ($StartService) {
        Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop

        if ($service.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
        }

        $service.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))
    }

    $service.Refresh()
    Write-Log "Verified service '$Name' with status '$($service.Status)'."
}

function Assert-AppxPresent {
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $installed = Get-AppxPackage `
        -AllUsers `
        -Name $PackageName `
        -ErrorAction SilentlyContinue |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    $provisioned = Get-AppxProvisionedPackage -Online |
        Where-Object {
            $_.DisplayName -eq $PackageName -or
            $_.DisplayName -like "$PackageName*"
        } |
        Select-Object -First 1

    if (-not $installed -and -not $provisioned) {
        throw "$DisplayName package '$PackageName' is neither installed nor provisioned."
    }

    if ($installed) {
        Write-Log "Verified $DisplayName installed package version '$($installed.Version)'."
    }
    else {
        Write-Log "Verified $DisplayName provisioned package '$($provisioned.PackageName)'."
    }
}

function Find-RequiredFile {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $resolved = $Paths |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $resolved) {
        throw "$DisplayName is missing. Checked: $($Paths -join '; ')"
    }

    Write-Log "Verified $DisplayName at '$resolved'."
    return $resolved
}

function Assert-WebView2Installed {
    $roots = @(
        "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application",
        "$env:ProgramFiles\Microsoft\EdgeWebView\Application"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $webView2 = $roots |
        ForEach-Object {
            Get-ChildItem `
                -LiteralPath $_ `
                -Filter 'msedgewebview2.exe' `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue
        } |
        Select-Object -First 1

    if (-not $webView2) {
        throw 'Microsoft Edge WebView2 Runtime is missing.'
    }

    Write-Log "Verified WebView2 at '$($webView2.FullName)'."
}

Write-Log 'Starting conservative employee desktop image preparation.'

$operatingSystem = Get-CimInstance Win32_OperatingSystem
Write-Log "Operating system: $($operatingSystem.Caption), version $($operatingSystem.Version), build $($operatingSystem.BuildNumber)."

if ($operatingSystem.Caption -notmatch 'Windows 11' -or
    $operatingSystem.Caption -notmatch 'multi-session|Virtual Desktops') {
    throw "This script requires a Windows 11 Enterprise multi-session source image. Detected '$($operatingSystem.Caption)'."
}

# Azure uses the virtual DVD drive during provisioning from a generalized image.
Set-DwordValue `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom' `
    -Name 'Start' `
    -Value 1
Write-Log 'Enabled the CD/DVD-ROM service for Azure provisioning.'

# Fail before capture if the Azure VM Agent is unhealthy.
Assert-ServicePresent -Name 'RdAgent'
Assert-ServicePresent -Name 'WindowsAzureGuestAgent'
Assert-ServicePresent `
    -Name 'WindowsAzureTelemetryService' `
    -Required $false `
    -StartService $false

# Low-risk AVD and consumer-experience settings. Intune can supersede these.
Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
    -Name 'fEnableTimeZoneRedirection' `
    -Value 1

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

Write-Log 'Applied conservative AVD and Windows consumer-experience settings.'

# Microsoft 365 Apps on a pooled multi-user host requires shared-computer activation.
Set-StringValue `
    -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' `
    -Name 'SharedComputerLicensing' `
    -Value '1'

$sharedComputerLicensing = (Get-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' `
    -Name 'SharedComputerLicensing' `
    -ErrorAction Stop).SharedComputerLicensing

if ([string]$sharedComputerLicensing -ne '1') {
    throw 'Microsoft 365 Apps shared-computer activation could not be enabled.'
}

Write-Log 'Enabled and verified Microsoft 365 Apps shared-computer activation.'

# Validate the Microsoft 365 Apps payload supplied by the Marketplace source.
$officeRoots = @(
    "$env:ProgramFiles\Microsoft Office\root\Office16",
    "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16"
)

$officeExecutables = [ordered]@{
    'Microsoft Word'       = 'WINWORD.EXE'
    'Microsoft Excel'      = 'EXCEL.EXE'
    'Microsoft PowerPoint' = 'POWERPNT.EXE'
    'Microsoft Outlook'    = 'OUTLOOK.EXE'
}

foreach ($application in $officeExecutables.GetEnumerator()) {
    $candidatePaths = foreach ($root in $officeRoots) {
        Join-Path $root $application.Value
    }

    Find-RequiredFile `
        -Paths $candidatePaths `
        -DisplayName $application.Key | Out-Null
}

Assert-ServicePresent -Name 'ClickToRunSvc'

# FSLogix is supplied by all Windows Enterprise multi-session Marketplace images.
# Its environment-specific profile path and authentication settings stay unset here.
$fsLogixPath = Find-RequiredFile `
    -Paths @("$env:ProgramFiles\FSLogix\Apps\frxsvc.exe") `
    -DisplayName 'FSLogix Apps Service'

$fsLogixVersion = (Get-Item -LiteralPath $fsLogixPath).VersionInfo.FileVersion
Write-Log "Verified FSLogix version '$fsLogixVersion'."
Assert-ServicePresent -Name 'frxsvc'

$profileRegistryPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'
if (Test-Path -LiteralPath $profileRegistryPath) {
    $profileSettings = Get-ItemProperty `
        -Path $profileRegistryPath `
        -ErrorAction SilentlyContinue

    $profilePropertyNames = @($profileSettings.PSObject.Properties.Name)

    if ($profilePropertyNames -contains 'Enabled' -or
        $profilePropertyNames -contains 'VHDLocations' -or
        $profilePropertyNames -contains 'CCDLocations') {
        throw 'Environment-specific FSLogix profile configuration was detected in the generalized image. Configure FSLogix through Intune after deployment instead.'
    }
}

Write-Log 'Verified that FSLogix profile-container settings are not baked into the image.'

# Validate Teams from the Microsoft-provided optimization customization.
Set-DwordValue `
    -Path 'HKLM:\SOFTWARE\Microsoft\Teams' `
    -Name 'IsWVDEnvironment' `
    -Value 1

Assert-AppxPresent `
    -PackageName 'MSTeams' `
    -DisplayName 'Microsoft Teams'

$teamsEnvironmentValue = (Get-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Teams' `
    -Name 'IsWVDEnvironment' `
    -ErrorAction Stop).IsWVDEnvironment

if ([int]$teamsEnvironmentValue -ne 1) {
    throw 'The Teams IsWVDEnvironment registry value is not set to 1.'
}

Write-Log 'Verified the Teams AVD environment configuration.'

# Preserve and validate components commonly broken by aggressive image cleanup.
Find-RequiredFile `
    -Paths @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) `
    -DisplayName 'Microsoft Edge' | Out-Null

Assert-WebView2Installed
Assert-AppxPresent -PackageName 'Microsoft.WindowsStore' -DisplayName 'Microsoft Store'
Assert-AppxPresent -PackageName 'Microsoft.DesktopAppInstaller' -DisplayName 'App Installer'

$explorerPath = Join-Path $env:WINDIR 'explorer.exe'
Find-RequiredFile -Paths @($explorerPath) -DisplayName 'Windows shell' | Out-Null

# Azure Image Builder reads this exact file during its hidden deprovision phase.
# The override treats telemetry as optional, checks required agent services,
# removes only stale unattended setup files, and runs VM-aware Sysprep.
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

    Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop

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

Write-Output '>>> Verifying Azure VM Agent services before Sysprep ...'
Wait-RequiredService -Name 'RdAgent'
Wait-RequiredService -Name 'WindowsAzureGuestAgent'
Wait-RequiredService -Name 'WindowsAzureTelemetryService' -Required $false

New-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom' `
    -Name 'Start' `
    -PropertyType DWord `
    -Value 1 `
    -Force | Out-Null

# Let servicing and Azure Agent activity settle after the final restart.
Start-Sleep -Seconds 90

Write-Output '>>> Removing stale unattended setup files ...'
$unattendFiles = @(
    "$env:SystemRoot\System32\Sysprep\unattend.xml",
    "$env:SystemRoot\Panther\unattend.xml",
    "$env:SystemRoot\Panther\Unattend\unattend.xml"
)

foreach ($file in $unattendFiles) {
    Remove-Item `
        -LiteralPath $file `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Output '>>> Starting Sysprep for an Azure VM image ...'
$sysprep = Start-Process `
    -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
    -ArgumentList '/oobe','/generalize','/quiet','/quit','/mode:vm' `
    -Wait `
    -PassThru

if ($sysprep.ExitCode -ne 0) {
    Write-Output ">>> Sysprep failed with exit code $($sysprep.ExitCode). Recent setuperr.log entries follow:"
    Get-Content `
        "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log" `
        -Tail 120 `
        -ErrorAction SilentlyContinue

    throw "Sysprep exited with code $($sysprep.ExitCode)."
}

$expectedState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
$deadline = (Get-Date).AddMinutes(20)
$imageState = $null

do {
    $imageState = (Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
        -Name 'ImageState' `
        -ErrorAction Stop).ImageState

    Write-Output ">>> ImageState: $imageState"

    if ($imageState -eq $expectedState) {
        Write-Output '>>> Sysprep completed successfully.'
        exit 0
    }

    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

Write-Output ">>> Sysprep did not reach '$expectedState'. Recent logs follow:"
Get-Content `
    "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log" `
    -Tail 120 `
    -ErrorAction SilentlyContinue
Get-Content `
    "$env:SystemRoot\System32\Sysprep\Panther\setupact.log" `
    -Tail 120 `
    -ErrorAction SilentlyContinue

throw "Timed out waiting for image state '$expectedState'. Last state was '$imageState'."
'@

Set-Content `
    -Path 'C:\DeprovisioningScript.ps1' `
    -Value $deprovisioningScript `
    -Encoding UTF8 `
    -Force

Write-Log 'Installed the Azure Image Builder deprovisioning and Sysprep override.'
Write-Log 'Conservative employee desktop image preparation completed successfully.'

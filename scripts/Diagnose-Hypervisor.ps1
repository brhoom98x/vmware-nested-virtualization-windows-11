<#
.SYNOPSIS
    Finds what is keeping the Windows hypervisor loaded and blocking nested virtualization.

.DESCRIPTION
    Read-only. Reports every mechanism that can load the Windows hypervisor, then prints a
    verdict naming the specific consumer rather than leaving you to interpret raw output.

    Checks all of:
      - Whether a hypervisor is running, and whether the CPU extensions are masked
      - Virtualization-Based Security running state
      - EVERY subkey under DeviceGuard\Scenarios  (not just Memory Integrity -- this is
        where Windows Hello ESS hides, and it is the check other guides omit)
      - Hypervisor-related optional features, via WMI rather than the DISM module
      - The BCD hypervisorlaunchtype setting, when run elevated
      - Which installer last enabled a feature, from the DISM log
      - The Monitor Mode recorded in any VMware VM logs you point it at

.PARAMETER VmPath
    Optional folder to search for vmware.log files, e.g. 'F:\VMs'. Monitor Mode is the
    authoritative confirmation of ULM vs CPL0.

.EXAMPLE
    .\Diagnose-Hypervisor.ps1

.EXAMPLE
    .\Diagnose-Hypervisor.ps1 -VmPath 'F:\VMs'

.NOTES
    Needs no elevation. The BCD check is the only part that does, and it degrades gracefully.
#>
[CmdletBinding()]
param(
    [string] $VmPath
)

$ErrorActionPreference = 'Continue'

function Write-Section ($Title) {
    Write-Host ''
    Write-Host "=== $Title " -NoNewline -ForegroundColor Cyan
    Write-Host ('=' * [Math]::Max(0, 60 - $Title.Length)) -ForegroundColor Cyan
}

function Write-Field ($Name, $Value, $Good) {
    $color = if ($null -eq $Good) { 'Gray' } elseif ($Good) { 'Green' } else { 'Yellow' }
    Write-Host ('  {0,-44}' -f $Name) -NoNewline
    Write-Host $Value -ForegroundColor $color
}

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------- hypervisor + CPU
Write-Section 'Hypervisor and CPU extensions'

$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

$hypervisorPresent = [bool] $cs.HypervisorPresent

Write-Field 'HypervisorPresent'                        $hypervisorPresent            (-not $hypervisorPresent)
Write-Field 'VMMonitorModeExtensions'                  $cpu.VMMonitorModeExtensions  ([bool] $cpu.VMMonitorModeExtensions)
Write-Field 'SecondLevelAddressTranslationExtensions'  $cpu.SecondLevelAddressTranslationExtensions ([bool] $cpu.SecondLevelAddressTranslationExtensions)
Write-Field 'VirtualizationFirmwareEnabled'            $cpu.VirtualizationFirmwareEnabled ([bool] $cpu.VirtualizationFirmwareEnabled)
Write-Field 'CPU'                                      $cpu.Name $null

if ($hypervisorPresent) {
    Write-Host '  -> The CPU flags above read False BECAUSE a hypervisor is masking them.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- VBS
Write-Section 'Virtualization-Based Security'

$vbsStatusText = @{ 0 = '0  not enabled'; 1 = '1  enabled, not running'; 2 = '2  ENABLED AND RUNNING' }
try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
                          -ClassName Win32_DeviceGuard -ErrorAction Stop
    $vbs = [int] $dg.VirtualizationBasedSecurityStatus
    Write-Field 'VirtualizationBasedSecurityStatus' $vbsStatusText[$vbs] ($vbs -eq 0)
    Write-Field 'SecurityServicesRunning' (($dg.SecurityServicesRunning -join ',') -replace '^$', '0') $null
} catch {
    Write-Field 'Win32_DeviceGuard' 'unavailable' $null
}

# ---------------------------------------------------------------- scenarios  (the key check)
Write-Section 'DeviceGuard scenarios  (all of them)'

$scenarioRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios'
$enabledScenarios = @()

if (Test-Path $scenarioRoot) {
    foreach ($key in Get-ChildItem $scenarioRoot) {
        $enabled = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).Enabled
        $state   = if ($null -eq $enabled) { '(no Enabled value)' } else { $enabled }
        if ($enabled -eq 1) { $enabledScenarios += $key.PSChildName }
        Write-Field $key.PSChildName $state ($enabled -ne 1)
    }
} else {
    Write-Host '  Scenarios key absent.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- optional features
Write-Section 'Hypervisor-related optional features'

# Win32_OptionalFeature avoids the DISM module, which throws "Class not registered"
# under PowerShell 7.
$featureStates = @{ 1 = 'ENABLED'; 2 = 'Disabled'; 3 = 'Absent' }
$enabledFeatures = @()

Get-CimInstance Win32_OptionalFeature -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform|DisposableClientVM|Subsystem-Linux' } |
    Sort-Object InstallState, Name |
    ForEach-Object {
        $state = $featureStates[[int] $_.InstallState]
        if ($state -eq 'ENABLED') { $enabledFeatures += $_.Name }
        Write-Field $_.Name $state ($state -ne 'ENABLED')
    }

# ---------------------------------------------------------------- BCD
Write-Section 'Boot configuration'

if ($isElevated) {
    $launchType = (bcdedit /enum "{current}" | Select-String 'hypervisorlaunchtype')
    if ($launchType) {
        $value = ($launchType.Line -split '\s+')[-1]
        Write-Field 'hypervisorlaunchtype' $value ($value -ieq 'Off')
    } else {
        Write-Field 'hypervisorlaunchtype' 'not set (defaults to Auto)' $false
    }
} else {
    Write-Host '  Not elevated -- bcdedit returns nothing at all without it.' -ForegroundColor DarkGray
    Write-Host '  Re-run as Administrator to read hypervisorlaunchtype.'      -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- who enabled it
Write-Section 'Recent feature enablement  (DISM log)'

$dismLog = Join-Path $env:WinDir 'Logs\DISM\dism.log'
if (Test-Path $dismLog) {
    $hits = Select-String -Path $dismLog -Pattern 'enable-feature' -ErrorAction SilentlyContinue |
            Select-Object -Last 5
    if ($hits) {
        foreach ($hit in $hits) {
            $line = $hit.Line.Trim()
            if ($line.Length -gt 150) { $line = $line.Substring(0, 150) + '...' }
            Write-Host "  $line" -ForegroundColor DarkGray
        }
    } else {
        Write-Host '  No enable-feature entries found.' -ForegroundColor DarkGray
    }
} else {
    Write-Host '  dism.log not readable.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- VMware monitor mode
if ($VmPath -and (Test-Path $VmPath)) {
    Write-Section 'VMware Monitor Mode'

    $lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Write-Host "  Last boot: $lastBoot" -ForegroundColor DarkGray
    Write-Host '  Any log written BEFORE that time is stale -- it records the previous session.' -ForegroundColor DarkGray
    Write-Host ''

    Get-ChildItem $VmPath -Filter 'vmware.log' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
            $mode  = (Select-String -Path $_.FullName -Pattern 'Monitor Mode' | Select-Object -Last 1)
            $text  = if ($mode) { ($mode.Line -replace '.*(Monitor Mode)', '$1').Trim() } else { 'no Monitor Mode line' }
            $stale = $_.LastWriteTime -lt $lastBoot
            $vm    = Split-Path (Split-Path $_.FullName -Parent) -Leaf
            $color = if ($stale) { 'DarkGray' } elseif ($text -match 'CPL0') { 'Green' } else { 'Yellow' }
            Write-Host ('  {0,-26} {1,-22} {2}{3}' -f $vm, $_.LastWriteTime, $text, $(if ($stale) { '   [STALE]' } else { '' })) -ForegroundColor $color
        }
}

# ---------------------------------------------------------------- verdict
Write-Section 'VERDICT'

if (-not $hypervisorPresent) {
    Write-Host '  No hypervisor is running. This is not your problem.' -ForegroundColor Green
    if (-not $cpu.VirtualizationFirmwareEnabled) {
        Write-Host '  BUT virtualization is disabled in firmware -- enable SVM (AMD) or VT-x (Intel) in BIOS.' -ForegroundColor Yellow
    }
} elseif ($enabledFeatures -contains 'HypervisorPlatform' -and $enabledFeatures.Count -eq 1) {
    Write-Host '  Windows Hypervisor Platform is enabled, and nothing else is.' -ForegroundColor Yellow
    Write-Host '  A QEMU-backed app (Try Omarchy, QEMU, VirtualBox 7, Android Studio) enabled it for itself.'
    Write-Host ''
    Write-Host '  -> Prefer a separate boot entry over removing the feature. The app re-enables' -ForegroundColor Cyan
    Write-Host '     WHP the next time it launches and finds it gone.' -ForegroundColor Cyan
} elseif ($enabledFeatures.Count -gt 0) {
    Write-Host "  These hypervisor features are enabled: $($enabledFeatures -join ', ')" -ForegroundColor Yellow
    Write-Host '  -> Disable them, then set hypervisorlaunchtype off.' -ForegroundColor Cyan
} elseif ($enabledScenarios -contains 'HypervisorEnforcedCodeIntegrity') {
    Write-Host '  Memory Integrity (HVCI) is on.' -ForegroundColor Yellow
    Write-Host '  -> Windows Security > Device security > Core isolation > off. Reboot.' -ForegroundColor Cyan
} elseif ($enabledScenarios -contains 'WindowsHello') {
    Write-Host '  Windows Hello Enhanced Sign-in Security (ESS) is the sole VBS consumer.' -ForegroundColor Yellow
    Write-Host '  This appears in NEITHER the Hyper-V feature list NOR the Core isolation UI.'
    Write-Host ''
    Write-Host '  -> Set Scenarios\WindowsHello\Enabled = 0 and hypervisorlaunchtype off.' -ForegroundColor Cyan
    Write-Host '  !! This destroys the whole Hello enrolment, PIN included. Know your' -ForegroundColor Red
    Write-Host '     account password first, then re-enrol with Reset-WindowsHello.ps1.' -ForegroundColor Red
} else {
    Write-Host '  A hypervisor is running but no feature or VBS scenario explains it.' -ForegroundColor Yellow
    Write-Host '  -> The BCD is launching it on its own. hypervisorlaunchtype off is enough.' -ForegroundColor Cyan
}

Write-Host ''

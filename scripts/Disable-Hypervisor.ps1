<#
.SYNOPSIS
    Stops the Windows hypervisor from launching, freeing the CPU virtualization
    extensions for VMware Workstation's ring-0 monitor.

.DESCRIPTION
    Run Diagnose-Hypervisor.ps1 FIRST and let it tell you which switches you need.
    With no switches this only sets the boot configuration, which is the load-bearing
    change and the one that works regardless of which consumer asked for the hypervisor.

    Supports -WhatIf. Preview before committing.

.PARAMETER IncludeESS
    Also disable Windows Hello Enhanced Sign-in Security.

    !! This destroys the entire Windows Hello enrolment -- PIN, face and fingerprint all
    share one VBS-sealed container. Your account password still works, so you are not
    locked out, but you must re-enrol afterwards with Reset-WindowsHello.ps1.
    Confirm you know that password before using this switch.

.PARAMETER RemoveFeatures
    Also disable the Hyper-V / WHP / VMP optional features.

    Note: an app that enabled Windows Hypervisor Platform for itself will re-enable it on
    next launch. For that case prefer -BootEntry, which leaves the feature installed.

.PARAMETER BootEntry
    Instead of changing the current boot entry, create a second one named
    "Windows 11 (No Hyper-V)" with the hypervisor off. Use this when the machine also
    needs WSL2, Docker Desktop, Windows Sandbox or a QEMU-backed app.

.PARAMETER SkipBitLocker
    Skip the BitLocker suspend. Only use this if you have confirmed the volume is not
    encrypted -- editing the BCD on an encrypted volume can force a recovery-key prompt.

.EXAMPLE
    .\Disable-Hypervisor.ps1 -WhatIf

.EXAMPLE
    .\Disable-Hypervisor.ps1 -IncludeESS

.EXAMPLE
    .\Disable-Hypervisor.ps1 -BootEntry
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $IncludeESS,
    [switch] $RemoveFeatures,
    [switch] $BootEntry,
    [switch] $SkipBitLocker
)

$ErrorActionPreference = 'Stop'

function Step ($Message) { Write-Host "`n[*] $Message" -ForegroundColor Cyan }
function Ok   ($Message) { Write-Host "    $Message"   -ForegroundColor Green }
function Warn ($Message) { Write-Host "    $Message"   -ForegroundColor Yellow }

# ------------------------------------------------------------------ BitLocker
if (-not $SkipBitLocker) {
    Step 'Checking BitLocker'
    $protected = Get-BitLockerVolume -ErrorAction SilentlyContinue |
                 Where-Object { $_.ProtectionStatus -eq 'On' }

    if ($protected) {
        foreach ($volume in $protected) {
            Warn "$($volume.MountPoint) is encrypted."
            if ($PSCmdlet.ShouldProcess($volume.MountPoint, 'Suspend BitLocker for one reboot')) {
                Suspend-BitLocker -MountPoint $volume.MountPoint -RebootCount 1 | Out-Null
                Ok "Suspended for one reboot."
            }
        }
        Warn 'Have your recovery key available: account.microsoft.com/devices/recoverykey'
    } else {
        Ok 'No encrypted volumes with protection on.'
    }
}

# ------------------------------------------------------------------ ESS
if ($IncludeESS) {
    Step 'Disabling Windows Hello Enhanced Sign-in Security'
    Warn 'This removes the whole Hello enrolment, PIN included.'
    Warn 'Your account password is the only credential that survives.'

    $essKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\WindowsHello'
    if (Test-Path $essKey) {
        if ($PSCmdlet.ShouldProcess($essKey, 'Set Enabled = 0')) {
            Set-ItemProperty -Path $essKey -Name Enabled -Type DWord -Value 0
            Ok 'ESS scenario disabled. Re-enrol afterwards with Reset-WindowsHello.ps1.'
        }
    } else {
        Warn 'ESS scenario key not present -- nothing to do.'
    }
}

# ------------------------------------------------------------------ features
if ($RemoveFeatures) {
    Step 'Disabling hypervisor optional features'

    $features = @(
        'Microsoft-Hyper-V-All'
        'HypervisorPlatform'
        'VirtualMachinePlatform'
        'Containers-DisposableClientVM'
        'Windows-Defender-ApplicationGuard'
    )

    foreach ($feature in $features) {
        if ($PSCmdlet.ShouldProcess($feature, 'Disable optional feature')) {
            try {
                Disable-WindowsOptionalFeature -Online -FeatureName $feature `
                    -NoRestart -ErrorAction Stop | Out-Null
                Ok "disabled: $feature"
            } catch {
                Write-Host "    skipped:  $feature" -ForegroundColor DarkGray
            }
        }
    }
    Warn 'An app that enabled WHP for itself will re-enable it on next launch.'
    Warn 'If that applies, re-run with -BootEntry instead.'
}

# ------------------------------------------------------------------ boot config
if ($BootEntry) {
    Step 'Creating a separate boot entry'

    if ($PSCmdlet.ShouldProcess('{current}', 'Copy boot entry as "Windows 11 (No Hyper-V)"')) {
        # -join makes this a single string; -match on an ARRAY does not populate $Matches
        $output = (bcdedit /copy "{current}" /d "Windows 11 (No Hyper-V)") -join "`n"
        Write-Host "    $output" -ForegroundColor DarkGray

        if ($output -match '\{[0-9a-fA-F-]{36}\}') {
            $guid = $Matches[0]
            bcdedit /set $guid hypervisorlaunchtype off | Out-Null
            Ok "Entry created: $guid  (hypervisor off)"
            Ok 'Pick it at boot for nested virtualization; the normal entry keeps the hypervisor.'
        } else {
            Warn 'Could not parse the new GUID. Set it manually:'
            Warn '  bcdedit /set "{GUID}" hypervisorlaunchtype off'
        }
    }
} else {
    Step 'Stopping the hypervisor from launching'

    if ($PSCmdlet.ShouldProcess('current boot entry', 'Set hypervisorlaunchtype off')) {
        bcdedit /set hypervisorlaunchtype off | Out-Null
        bcdedit /set vsmlaunchtype Off        | Out-Null
        Ok 'hypervisorlaunchtype = off'
        Ok 'vsmlaunchtype = Off'
    }
}

# ------------------------------------------------------------------ done
Write-Host ''
Write-Host 'Reboot required. After rebooting, verify with:' -ForegroundColor Cyan
Write-Host '  .\Diagnose-Hypervisor.ps1' -ForegroundColor White
Write-Host ''
Write-Host 'You want HypervisorPresent False, and both CPU extension flags True.' -ForegroundColor DarkGray

if ($IncludeESS) {
    Write-Host ''
    Write-Host 'Windows Hello will report every option unavailable after the reboot.' -ForegroundColor Yellow
    Write-Host 'That is expected. Sign in with your password, then run Reset-WindowsHello.ps1.' -ForegroundColor Yellow
}

<#
.SYNOPSIS
    Reverses Disable-Hypervisor.ps1 -- puts the Windows hypervisor and VBS back.

.DESCRIPTION
    Restores hypervisorlaunchtype to Auto and, with -IncludeESS, re-enables the Windows
    Hello Enhanced Sign-in Security scenario.

    Note: re-enabling ESS does NOT hand back a PIN that was lost when VBS was removed.
    Windows has already dropped that enrolment, so you re-enrol either way. Turning ESS
    back on only means the NEW enrolment is VBS-sealed again.

    Optional features removed with -RemoveFeatures are not restored here -- use
    "Turn Windows features on or off", or Enable-WindowsOptionalFeature by name.

.PARAMETER IncludeESS
    Also set the Windows Hello ESS scenario back to enabled.

.PARAMETER RemoveBootEntry
    Delete a boot entry previously created with -BootEntry. Pass the GUID.

.EXAMPLE
    .\Restore-Hypervisor.ps1 -IncludeESS

.EXAMPLE
    .\Restore-Hypervisor.ps1 -RemoveBootEntry '{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}'
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $IncludeESS,
    [string] $RemoveBootEntry
)

$ErrorActionPreference = 'Stop'

function Step ($Message) { Write-Host "`n[*] $Message" -ForegroundColor Cyan }
function Ok   ($Message) { Write-Host "    $Message"   -ForegroundColor Green }

# ------------------------------------------------------------------ boot entry removal
if ($RemoveBootEntry) {
    Step "Deleting boot entry $RemoveBootEntry"
    if ($PSCmdlet.ShouldProcess($RemoveBootEntry, 'Delete boot entry')) {
        bcdedit /delete $RemoveBootEntry | Out-Null
        Ok 'Entry deleted.'
    }
    return
}

# ------------------------------------------------------------------ boot config
Step 'Restoring boot configuration'
if ($PSCmdlet.ShouldProcess('current boot entry', 'Set hypervisorlaunchtype auto')) {
    bcdedit /set hypervisorlaunchtype auto | Out-Null
    Ok 'hypervisorlaunchtype = auto'
}

# ------------------------------------------------------------------ ESS
if ($IncludeESS) {
    Step 'Re-enabling Windows Hello Enhanced Sign-in Security'
    $essKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\WindowsHello'

    if (Test-Path $essKey) {
        if ($PSCmdlet.ShouldProcess($essKey, 'Set Enabled = 1')) {
            Set-ItemProperty -Path $essKey -Name Enabled -Type DWord -Value 1
            Ok 'ESS scenario re-enabled.'
            Write-Host '    A PIN lost to the earlier change is not restored by this --' -ForegroundColor DarkGray
            Write-Host '    enrol a new one from Settings after rebooting.'               -ForegroundColor DarkGray
        }
    } else {
        Write-Host '    ESS scenario key not present.' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Reboot required.' -ForegroundColor Cyan
Write-Host 'Re-enable any optional features through "Turn Windows features on or off",' -ForegroundColor DarkGray
Write-Host 'and Memory Integrity through Windows Security > Device security.'           -ForegroundColor DarkGray

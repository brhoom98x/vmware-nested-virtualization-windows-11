<#
.SYNOPSIS
    Creates or repairs the "no hypervisor" boot entry, then arms it for the NEXT boot only.

.DESCRIPTION
    Idempotent. Run it as often as you like. It handles every way the boot-entry route
    can fail to take effect:

      - entry was never created          -> creates it
      - entry exists without the setting -> applies hypervisorlaunchtype off
      - entry missing from the boot menu -> adds it to the display order
      - boot menu never appears          -> sets a timeout
      - you booted the default by habit  -> arms /bootsequence so the NEXT restart
                                            uses the entry automatically, once

    /bootsequence is the important part. It is a one-shot override: the next boot uses
    the named entry without you needing to catch a menu, and the setting clears itself
    afterwards, so your default stays the normal entry with the hypervisor intact.

.PARAMETER Name
    Description of the boot entry. Must match what you created, if it already exists.

.PARAMETER NoArm
    Create/repair the entry but do NOT arm it for the next boot.

.EXAMPLE
    .\Use-NoHyperVEntry.ps1

.EXAMPLE
    .\Use-NoHyperVEntry.ps1 -NoArm
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $Name = 'Windows 11 (No Hyper-V)',
    [switch] $NoArm
)

$ErrorActionPreference = 'Stop'

function Step ($m) { Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "    $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "    $m"   -ForegroundColor Yellow }

# ------------------------------------------------------------------ parse existing entries
function Get-BootEntries {
    $entries = @()
    $cur = $null
    foreach ($line in (bcdedit /enum OSLOADER)) {
        if ($line -match '^identifier\s+(\{[^}]+\})') {
            if ($cur) { $entries += $cur }
            $cur = [pscustomobject]@{ Id = $Matches[1]; Description = ''; LaunchType = '(not set)' }
        }
        elseif ($cur -and $line -match '^description\s+(.+)$')          { $cur.Description = $Matches[1].Trim() }
        elseif ($cur -and $line -match '^hypervisorlaunchtype\s+(.+)$') { $cur.LaunchType  = $Matches[1].Trim() }
    }
    if ($cur) { $entries += $cur }
    return $entries
}

Step 'Current boot entries'
$entries = Get-BootEntries
$entries | Format-Table @{n='Identifier';e={$_.Id}},
                        @{n='Description';e={$_.Description}},
                        @{n='hypervisorlaunchtype';e={$_.LaunchType}} -AutoSize | Out-String | Write-Host

$target = $entries | Where-Object { $_.Description -eq $Name } | Select-Object -First 1

# ------------------------------------------------------------------ create if missing
if (-not $target) {
    Step "No entry named `"$Name`" exists -- creating it"
    $out = (bcdedit /copy "{current}" /d $Name) -join "`n"
    Write-Host "    $out" -ForegroundColor DarkGray

    if ($out -notmatch '\{[0-9a-fA-F-]{36}\}') {
        Warn 'Could not parse the new GUID from bcdedit output. Aborting.'
        exit 1
    }
    $guid = $Matches[0]
    Ok "Created: $guid"
} else {
    $guid = $target.Id
    Step "Entry already exists: $guid"
    Ok "hypervisorlaunchtype is currently: $($target.LaunchType)"
}

# ------------------------------------------------------------------ enforce the setting
Step 'Applying hypervisorlaunchtype off to that entry'
bcdedit /set $guid hypervisorlaunchtype off | Out-Null
Ok 'applied'

# ------------------------------------------------------------------ make sure it is selectable
Step 'Ensuring it appears in the boot menu'
bcdedit /displayorder $guid /addlast | Out-Null
Ok 'in display order'

$timeoutLine = (bcdedit /enum "{bootmgr}" | Select-String '^timeout')
if (-not $timeoutLine) {
    bcdedit /timeout 10 | Out-Null
    Ok 'boot menu timeout set to 10 seconds (was unset)'
} else {
    Ok "boot menu timeout: $(($timeoutLine.Line -split '\s+')[-1]) seconds"
}

# ------------------------------------------------------------------ arm the next boot
if (-not $NoArm) {
    Step 'Arming the NEXT boot to use this entry automatically'
    bcdedit /bootsequence $guid | Out-Null
    Ok 'armed -- the next restart goes straight into it, no menu needed'
    Ok 'This is one-shot. Boots after that return to your normal default.'
} else {
    Warn 'Not armed (-NoArm). You must pick the entry from the boot menu yourself.'
}

# ------------------------------------------------------------------ summary
Step 'Result'
Get-BootEntries | Format-Table @{n='Identifier';e={$_.Id}},
                               @{n='Description';e={$_.Description}},
                               @{n='hypervisorlaunchtype';e={$_.LaunchType}} -AutoSize | Out-String | Write-Host

Write-Host 'Now restart. After it comes back, verify with:' -ForegroundColor Cyan
Write-Host '  .\Diagnose-Hypervisor.ps1 -VmPath "F:\VMs"' -ForegroundColor White
Write-Host ''
Write-Host 'Expect HypervisorPresent False, both CPU extension flags True, VBS 0.' -ForegroundColor DarkGray
Write-Host 'Your DEFAULT entry is unchanged, so a normal boot still runs the' -ForegroundColor DarkGray
Write-Host 'hypervisor and Try Omarchy keeps working.' -ForegroundColor DarkGray

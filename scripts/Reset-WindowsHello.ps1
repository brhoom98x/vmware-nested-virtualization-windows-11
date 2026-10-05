<#
.SYNOPSIS
    Clears the stale Windows Hello (NGC) container so a new PIN can be enrolled after VBS
    was disabled.

.DESCRIPTION
    When Enhanced Sign-in Security was on and VBS is then removed, Hello's credential
    container stays sealed to a VBS that no longer exists. Every sign-in option reports
    "This option is currently unavailable" and dsregcmd /status shows NgcSet : NO.

    Windows does not repair this by itself and does not offer to. The container has to be
    emptied so a fresh one can be built.

    This deletes Windows Hello enrolments for EVERY user on the machine. The account
    password is unaffected and is how you sign in afterwards.

.PARAMETER Force
    Skip the interactive confirmation. Intended for unattended use only.

.EXAMPLE
    .\Reset-WindowsHello.ps1

.NOTES
    Verify you know the account password BEFORE running this. On a Microsoft account,
    check it at account.microsoft.com from another device first.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$ngc = Join-Path $env:WinDir 'ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'

Write-Host ''
Write-Host '  Windows Hello container reset' -ForegroundColor Cyan
Write-Host '  ----------------------------' -ForegroundColor Cyan
Write-Host "  Target: $ngc"
Write-Host ''
Write-Host '  This removes PIN, face and fingerprint enrolments for all users.' -ForegroundColor Yellow
Write-Host '  Your account PASSWORD still works and is how you will sign in next.' -ForegroundColor Yellow
Write-Host ''

# ------------------------------------------------------------------ current state
$ngcSet = (dsregcmd /status | Select-String 'NgcSet').Line
if ($ngcSet) { Write-Host "  Current state:$($ngcSet -replace '\s+', ' ')" -ForegroundColor DarkGray }

# ------------------------------------------------------------------ confirm
if (-not $Force) {
    Write-Host ''
    $answer = Read-Host '  Do you know your account password? Type YES to continue'
    if ($answer -cne 'YES') {
        Write-Host '  Aborted. Verify the password first, then re-run.' -ForegroundColor Red
        return
    }
}

if (-not (Test-Path $ngc)) {
    Write-Host '  NGC folder not found -- nothing to clear.' -ForegroundColor Yellow
    return
}

# ------------------------------------------------------------------ clear
if ($PSCmdlet.ShouldProcess($ngc, 'Take ownership and empty the Hello container')) {

    Write-Host ''
    Write-Host '[*] Taking ownership' -ForegroundColor Cyan
    takeown /f $ngc /r /d y | Out-Null
    icacls $ngc /grant "$($env:USERNAME):F" /t | Out-Null

    Write-Host '[*] Emptying the container' -ForegroundColor Cyan
    Remove-Item (Join-Path $ngc '*') -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host '[*] Handing ownership back to the system' -ForegroundColor Cyan
    icacls $ngc /t /q /c /reset | Out-Null

    Write-Host ''
    Write-Host '  Done. Reboot, then:' -ForegroundColor Green
    Write-Host '    Settings > Accounts > Sign-in options > PIN (Windows Hello) > Set up' -ForegroundColor White
    Write-Host ''
    Write-Host '  The new PIN is enrolled without ESS, so it survives the hypervisor' -ForegroundColor DarkGray
    Write-Host '  staying off. Confirm with:  dsregcmd /status | findstr NgcSet'       -ForegroundColor DarkGray
    Write-Host '  You want NgcSet : YES'                                              -ForegroundColor DarkGray
}

# Escaping ULM Mode

**Why VMware Workstation's nested virtualization silently fails on Windows 11 — and how to find the invisible feature holding the hypervisor hostage.**

You tick *Virtualize Intel VT-x/EPT* or *AMD-V/RVI*, the VM refuses to start, and Windows gives you this and nothing else:

> Failed to start the virtual machine.

Every guide online tells you to disable Hyper-V and turn off Memory Integrity. This repo is for the case where **you already did all of that and the hypervisor is still running.**

---

## TL;DR

If `HypervisorPresent` is `True` but no Hyper-V feature explains it, enumerate **every** subkey under:

```
HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios
```

Not just `HypervisorEnforcedCodeIntegrity`. The usual advice only ever checks that one.

Two consumers hide there that no checklist mentions and neither the Hyper-V feature list nor the Core Isolation UI will show you:

| Consumer | Where it hides | Why it's missed |
|---|---|---|
| **Windows Hello Enhanced Sign-in Security (ESS)** | `Scenarios\WindowsHello\Enabled = 1` | VBS-backed, on by default, invisible in every GUI |
| **Windows Hypervisor Platform (WHP)** | An optional feature a QEMU-backed app enabled for itself | Installed silently; the app re-enables it when you remove it |

## The mechanism

```
A VBS consumer is enabled
        ↓
Windows loads its own hypervisor at boot  (hvax64.exe / hvix64.exe)
        ↓
The hypervisor claims AMD-V/RVI or VT-x/EPT exclusively
        ↓
VMware Workstation demotes itself to a user-level monitor  (Monitor Mode: ULM)
        ↓
Nested virtualization is unavailable — a ULM cannot pass the
extensions down to a guest, so vhv.enable makes power-on fail
```

`hvax64.exe` and `hvix64.exe` ship with Windows whether or not the Hyper-V role is installed, so **no feature needs to be enabled for this to happen.**

The trap is that **ULM mode still boots ordinary VMs perfectly.** Nothing looks wrong until the day you need nested virt.

## The three signals that identify it

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object HypervisorPresent
Get-CimInstance Win32_Processor |
  Select-Object VMMonitorModeExtensions, SecondLevelAddressTranslationExtensions
```

| Signal | Hypervisor present | Extensions free |
|---|---|---|
| `HypervisorPresent` | `True` | `False` |
| `VMMonitorModeExtensions` | `False` | `True` |
| `SecondLevelAddressTranslationExtensions` | `False` | `True` |

The CPU flags read `False` **because** a hypervisor is masking them from the OS. That inversion is the fastest tell you have.

The authoritative confirmation is in the VM's own `vmware.log`, in the VM's folder:

```
vmware-vmx.exe  Monitor Mode: ULM     ← hypervisor owns the CPU
vmware-vmx.exe  Monitor Mode: CPL0    ← Workstation has its ring-0 monitor
```

> **Check the log's timestamp against `LastBootUpTime` before trusting it.** A log only records the mode from the run that produced it. After a reboot every existing log still says `ULM` until you actually start a VM again — which looks exactly like a failed fix.

## Usage

All scripts are PowerShell. Diagnosis is read-only and needs no elevation.

```powershell
# 1. Find out what is actually holding the hypervisor up
.\scripts\Diagnose-Hypervisor.ps1

# 2. Apply the fix the diagnosis points to (elevated, reboots)
.\scripts\Disable-Hypervisor.ps1 -WhatIf     # preview first
.\scripts\Disable-Hypervisor.ps1

# 3. Put everything back (elevated)
.\scripts\Restore-Hypervisor.ps1
```

`Diagnose-Hypervisor.ps1` prints a verdict naming the specific consumer, so you don't have to interpret the raw output yourself.

## Pick the fix from what you found

Stop at the first row that matches.

| Finding | Meaning | Action |
|---|---|---|
| `HypervisorPresent` is `False` | Not your problem | Check firmware — `VirtualizationFirmwareEnabled` must be `True`, else enable SVM / VT-x in BIOS |
| `HypervisorPlatform` enabled, nothing else | A QEMU-backed app turned WHP on for itself | **Use a separate boot entry**, not feature removal — see below |
| Any other Hyper-V feature enabled | Hyper-V, WSL2 or Sandbox owns the CPU | Disable the features, then set `hypervisorlaunchtype off` |
| `HypervisorEnforcedCodeIntegrity = 1` | Memory Integrity is on | Windows Security → Device security → Core isolation → off |
| `WindowsHello = 1`, all other scenarios `0` | **ESS alone is holding it up** | Set that value to `0` + `hypervisorlaunchtype off` |
| All scenarios `0`, no features enabled | The BCD is launching it on its own | `hypervisorlaunchtype off` alone is enough |

### Naming the culprit instead of guessing

If a feature came back enabled and you don't know what did it, the DISM log records the exact command line and timestamp:

```powershell
Select-String -Path 'C:\Windows\Logs\DISM\dism.log' -Pattern 'enable-feature' |
  Select-Object -Last 10
```

That one grep is how the WHP case in this repo was identified — an installer had run `dism /online /enable-feature /featurename:HypervisorPlatform /all /norestart /quiet` without asking.

---

## ⚠️ Disabling ESS destroys the entire Windows Hello enrolment — PIN included

This is the part that is not documented anywhere and will catch you out.

Hello's PIN, face and fingerprint all share **one VBS-sealed container**. Remove VBS and that container becomes unreadable, so all three go *"This option is currently unavailable"* at once and `dsregcmd /status` reports `NgcSet : NO`.

- **You are not locked out.** The account password still works.
- **Know that password before you start.** It is the only credential that survives.
- **Reverting ESS does not hand the old PIN back** — Windows has already dropped the enrolment. You must re-enrol either way.

Recovery is `scripts\Reset-WindowsHello.ps1`: clear the stale container, reboot, enrol a new PIN. The new PIN is created without ESS, so it survives the hypervisor staying off.

## When something else genuinely needs the hypervisor

Turning the hypervisor off globally breaks WSL2, Docker Desktop's WSL2 and Hyper-V backends, Windows Sandbox, and any QEMU-backed app accelerating through WHP.

Don't toggle the feature back and forth. **An app that enabled WHP for itself will simply enable it again the next time it starts and finds it missing — it never asks.** Removing the feature buys you one reboot, not a fixed machine.

Control the *boot entry* instead:

```powershell
bcdedit /copy "{current}" /d "Windows 11 (No Hyper-V)"
bcdedit /set "{PASTE-GUID-HERE}" hypervisorlaunchtype off
```

Pick *Windows 11 (No Hyper-V)* at boot for nested-virtualization work, and the normal entry for containers and QEMU guests. The app never notices anything is wrong.

## Gotchas worth knowing

- **`Get-WindowsOptionalFeature -Online` fails with `Class not registered`** under PowerShell 7 — the DISM module's COM interface doesn't load there. Use `Get-CimInstance Win32_OptionalFeature` instead, or run that cmdlet in Windows PowerShell 5.1. It is not a sign of a broken machine.
- **`bcdedit` produces no output at all without elevation**, which reads as an empty result rather than an error.
- **Enabling any hypervisor feature resets `hypervisorlaunchtype` to `Auto`**, silently overriding an earlier `off`. Re-read it after any app has touched the feature list.
- **`hvservice` and `Vid` may still show as Running after the fix.** They load regardless and have no hypervisor to attach to. The CPUID and VBS results are authoritative.
- **Suspend BitLocker before editing the BCD** (`Suspend-BitLocker -MountPoint "C:" -RebootCount 1`), or you may meet a recovery-key prompt at next boot.
- **Nested virtualization cannot be toggled on a suspended VM.** Power it fully off first.

## Documentation

A formatted version of the full runbook, with the diagnostic commands laid out step by step:

- [`docs/escaping-ulm-mode.html`](docs/escaping-ulm-mode.html) — open in a browser
- [`docs/escaping-ulm-mode.pdf`](docs/escaping-ulm-mode.pdf) — 12 pages, A4, print-formatted

## Scope

Written against **Windows 11 Pro 26xxx** and **VMware Workstation 25.0.0**, verified on an AMD Ryzen desktop. The mechanism applies to Intel hosts identically — substitute VT-x/EPT for AMD-V/RVI and `hvix64.exe` for `hvax64.exe`.

Security trade-off, stated plainly: this turns off Virtualization-Based Security. Credential Guard and Memory Integrity stay off as a consequence. On a lab machine that is a reasonable trade; on a machine holding domain credentials, weigh it deliberately.

## License

MIT — see [LICENSE](LICENSE).

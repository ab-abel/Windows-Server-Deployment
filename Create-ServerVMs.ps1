#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates many Windows Server VMs on Hyper-V from scratch (unattended ISO install).

.PARAMETER ConfigPath
    JSON file with "defaults" and a "vms" list. Default: vms-settings.json next to the script.
.PARAMETER XmlPath
    Answer-file template. Default: autounattend-server-index.xml next to the script.
.PARAMETER BatchSize
    How many VMs to start at the same time. The next batch starts after the
    boot-prompt key presses for the current one are done. Default: 4.
.PARAMETER WaitForInstall
    Wait for every VM to finish installing, then eject the ISOs and delete the
    temporary answer-file ISOs (they contain the password in plain text).
.PARAMETER TimeoutMinutes
    Per-VM wait limit when -WaitForInstall is used.

.EXAMPLE
    .\Create-ServerVMs.ps1
    .\Create-ServerVMs.ps1 -BatchSize 2 -WaitForInstall
#>
param(
    [string]$ConfigPath  = (Join-Path $PSScriptRoot 'vms-settings.json'),
    [string]$XmlPath     = (Join-Path $PSScriptRoot 'autounattend-server-index.xml'),
    [int]$BatchSize      = 4,
    [switch]$WaitForInstall,
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'

# ======================================================================
# Helpers
# ======================================================================

function Get-Setting($vm, [string]$Name) {
    if ($null -ne $vm.$Name -and "$($vm.$Name)" -ne '') { return $vm.$Name }
    return $script:defaults.$Name
}

function ConvertTo-XmlSafe([string]$Text) {
    [System.Security.SecurityElement]::Escape($Text)
}

if (-not ('IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class IsoWriter {
  public static void Write(string path, object stream, int blockSize, int totalBlocks) {
    IStream s = (IStream)stream;
    using (FileStream o = File.Create(path)) {
      byte[] buf = new byte[blockSize];
      IntPtr pcb = Marshal.AllocHGlobal(4);
      try {
        for (int i = 0; i < totalBlocks; i++) {
          s.Read(buf, blockSize, pcb);
          o.Write(buf, 0, Marshal.ReadInt32(pcb));
        }
      } finally { Marshal.FreeHGlobal(pcb); }
    }
  }
}
'@
}

# Build a small ISO containing autounattend.xml
function New-AnswerFileIso([string]$XmlContent, [string]$IsoPath) {
    $stage = Join-Path $env:TEMP ('unattend-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Set-Content -Path (Join-Path $stage 'autounattend.xml') -Value $XmlContent -Encoding UTF8
        Remove-Item $IsoPath -ErrorAction SilentlyContinue

        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 4          # UDF
        $fsi.VolumeName = 'UNATTEND'
        $fsi.Root.AddTree($stage, $false)
        $img = $fsi.CreateResultImage()
        [IsoWriter]::Write($IsoPath, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
    }
    finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Tap Enter on several VMs at once to get past "Press any key to boot from CD or DVD"
function Send-BootKeys([string[]]$VMNames, [int]$Seconds = 30) {
    $ns = 'root\virtualization\v2'
    $keyboards = foreach ($n in $VMNames) {
        $cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$n'"
        Get-CimInstance -Namespace $ns -ClassName Msvm_Keyboard -Filter "SystemName='$($cs.Name)'"
    }
    1..$Seconds | ForEach-Object {
        foreach ($kb in $keyboards) {
            Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = 13 } | Out-Null
        }
        Start-Sleep -Seconds 1
    }
}

# ======================================================================
# Load config and pre-flight checks
# ======================================================================

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
if (-not (Test-Path $XmlPath))    { throw "XML template not found: $XmlPath" }

$config          = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$script:defaults = $config.defaults
$xmlSource       = Get-Content $XmlPath -Raw
$vmList          = @($config.vms)

if ($vmList.Count -eq 0) { throw "No VMs listed in $ConfigPath." }

$dupes = $vmList | Group-Object { $_.name } | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate VM names in config: $($dupes.Name -join ', ')" }

# Password: use the config value, or ask once for all VMs
$sharedPass = $script:defaults.adminPassword
if ([string]::IsNullOrWhiteSpace($sharedPass)) {
    $secure     = Read-Host 'Administrator password for the new VMs' -AsSecureString
    $sharedPass = [System.Net.NetworkCredential]::new('', $secure).Password
}

# ======================================================================
# Phase 1: build every VM (not started yet)
# ======================================================================

$ready = @()     # VMs created and waiting to be started

foreach ($vm in $vmList) {
    $name = $vm.name

    try {
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
            Write-Warning "VM '$name' already exists. Skipping."
            continue
        }

        $vmPath    = Get-Setting $vm 'vmPath'
        $iso       = Get-Setting $vm 'isoPath'
        $switch    = Get-Setting $vm 'switch'
        $imageIdx  = Get-Setting $vm 'imageIndex'
        $cpu       = [int](Get-Setting $vm 'cpu')
        $memBytes  = [int64](Get-Setting $vm 'memoryGB') * 1GB
        $diskBytes = [int64](Get-Setting $vm 'diskGB') * 1GB
        $pass      = if ($vm.adminPassword) { $vm.adminPassword } else { $sharedPass }

        # Windows computer names max out at 15 characters
        $computerName = if ($vm.computerName) { $vm.computerName }
                        else { $name.Substring(0, [Math]::Min(15, $name.Length)) }

        Write-Host "`n=== Building $name ===" -ForegroundColor Cyan

        if (-not (Test-Path $iso)) { throw "ISO not found: $iso" }
        $null = Get-VMSwitch -Name $switch      # throws if the switch doesn't exist

        # Answer file -> ISO
        $xml = $xmlSource.
            Replace('{{IMAGEINDEX}}',   [string]$imageIdx).
            Replace('{{COMPUTERNAME}}', (ConvertTo-XmlSafe $computerName)).
            Replace('{{PASSWORD}}',     (ConvertTo-XmlSafe $pass))

        $unattendIso = Join-Path $env:TEMP "$name-unattend.iso"
        New-AnswerFileIso -XmlContent $xml -IsoPath $unattendIso

        # VM
        $vmDir   = Join-Path $vmPath $name
        $vhdPath = Join-Path $vmDir "$name.vhdx"
        New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

        New-VM -Name $name -Path $vmPath -Generation 2 `
               -MemoryStartupBytes $memBytes `
               -NewVHDPath $vhdPath -NewVHDSizeBytes $diskBytes `
               -SwitchName $switch | Out-Null
        Set-VMProcessor -VMName $name -Count $cpu
        Set-VMMemory    -VMName $name -DynamicMemoryEnabled $false -StartupBytes $memBytes

        $winDvd = Add-VMDvdDrive -VMName $name -Path $iso -Passthru
        Add-VMDvdDrive -VMName $name -Path $unattendIso
        Set-VMFirmware -VMName $name -FirstBootDevice $winDvd

        Write-Host "$name built ($cpu CPU, $($memBytes / 1GB)GB RAM, $($diskBytes / 1GB)GB disk)." -ForegroundColor Green
        $ready += [pscustomobject]@{ Name = $name; AnswerIso = $unattendIso }
    }
    catch {
        Write-Warning "Failed to build '$name': $($_.Exception.Message)"
    }
}

# ======================================================================
# Phase 2: start the VMs in batches and tap the boot-prompt key
# ======================================================================

if ($ready.Count -gt 0) {
    Write-Host "`nStarting $($ready.Count) VM(s) in batches of $BatchSize..." -ForegroundColor Cyan

    for ($i = 0; $i -lt $ready.Count; $i += $BatchSize) {
        $batch = @($ready[$i..([Math]::Min($i + $BatchSize, $ready.Count) - 1)])
        $names = $batch.Name

        Write-Host "Batch: $($names -join ', ')"
        $names | ForEach-Object { Start-VM -Name $_ }
        Send-BootKeys -VMNames $names
    }

    Write-Host "`nAll VMs are installing unattended (about 10-15 minutes each, in parallel)." -ForegroundColor Green
    Write-Host "Sign in as Administrator when each one finishes."
}

# ======================================================================
# Optional: wait for the installs, then clean up
# ======================================================================

if ($WaitForInstall -and $ready.Count -gt 0) {
    $pending = [System.Collections.ArrayList]@($ready)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    Write-Host "`nWaiting for installs to finish (timeout: $TimeoutMinutes min)..." -ForegroundColor Cyan

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        foreach ($p in @($pending)) {
            $hb = (Get-VMIntegrationService -VMName $p.Name -Name 'Heartbeat').PrimaryStatusDescription
            if ($hb -eq 'OK') {
                Start-Sleep -Seconds 60     # let first-boot setup finish reading the answer file
                Get-VMDvdDrive -VMName $p.Name | Set-VMDvdDrive -Path $null
                Remove-Item $p.AnswerIso -Force -ErrorAction SilentlyContinue
                Write-Host "$($p.Name) is up. ISOs ejected, answer-file ISO deleted." -ForegroundColor Green
                $pending.Remove($p)
            }
        }
    }

    foreach ($p in $pending) {
        Write-Warning "$($p.Name) did not report a heartbeat in time. ISOs left attached; delete $($p.AnswerIso) yourself after the install."
    }
}
elseif ($ready.Count -gt 0) {
    Write-Host "`nReminder: the answer-file ISOs in $env:TEMP contain the password in plain text."
    Write-Host "Delete them after the installs finish, or use -WaitForInstall next time."
}

Write-Host "`nDone."

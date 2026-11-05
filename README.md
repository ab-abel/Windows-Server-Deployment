# Hyper-V Windows Server VM Automation

Create one or many Windows Server 2022 virtual machines on a local Hyper-V host, **from scratch**, with no golden image. Edit a config file, run one script, and when it finishes you just sign in.

## Files

| File | Purpose |
|---|---|
| `Create-ServerVMs.ps1` | The script. Builds and starts the VMs. |
| `vms-settings.json` | Settings: defaults plus the list of VMs to create. |
| `autounattend-server-index.xml` | Answer-file template that makes Windows Setup run without any clicks. |

Keep all three in the same folder.

## Requirements

- Windows 10/11 Pro, Enterprise, or Education, or Windows Server, with the **Hyper-V** feature enabled
- Windows PowerShell **5.1**, run **as Administrator**
- A Windows Server 2022 ISO
- An existing Hyper-V virtual switch
- Enough free RAM and disk for all the VMs (memory is static)

## Quick start

1. Open `vms-settings.json` and set `isoPath`, `switch`, and `vmPath` under `defaults` to match your machine.
2. List the VMs you want under `vms`.
3. Open PowerShell as Administrator in the project folder and run:

```powershell
.\Create-ServerVMs.ps1
```

4. Wait about 10 to 15 minutes, then sign in as **Administrator** with the password from the config.

If scripts are blocked, run this first: `Set-ExecutionPolicy -Scope Process Bypass`

## Configuration

`defaults` apply to every VM. Any VM entry can override any default.

```json
{
  "defaults": {
    "vmPath": "E:\\",
    "isoPath": "E:\\iso\\WinServer_2022_SERVER_EVAL_English_x64.iso",
    "switch": "Sophos SW LAN",
    "adminPassword": "ChangeMe!2026",
    "imageIndex": 2,
    "cpu": 2,
    "memoryGB": 4,
    "diskGB": 40
  },
  "vms": [
    { "name": "Web03" },
    { "name": "DB01", "cpu": 4, "memoryGB": 8, "diskGB": 100 }
  ]
}
```

| Setting | Meaning |
|---|---|
| `name` | Hyper-V VM name (required for each VM) |
| `computerName` | Windows computer name. Defaults to the VM name cut to 15 characters. |
| `vmPath` | Folder where VM files are stored |
| `isoPath` | Windows Server ISO |
| `switch` | Name of the virtual switch to connect to |
| `adminPassword` | Administrator password. Leave it empty (`""`) to be prompted once. |
| `imageIndex` | Edition inside the ISO. For Server 2022: `1` = Standard (no GUI), `2` = Standard with Desktop Experience. |
| `cpu`, `memoryGB`, `diskGB` | VM size |

To list the editions in your ISO: mount it, then run `Get-WindowsImage -ImagePath <drive>:\sources\install.wim`.

## Script options

| Option | Default | Description |
|---|---|---|
| `-ConfigPath` | `vms-settings.json` | Use a different config file |
| `-XmlPath` | `autounattend-server-index.xml` | Use a different answer-file template |
| `-BatchSize` | `4` | How many VMs to start at the same time |
| `-WaitForInstall` | off | Wait for the installs to finish, then eject the ISOs and delete the temporary answer-file ISOs |
| `-TimeoutMinutes` | `60` | Wait limit per VM when using `-WaitForInstall` |

```powershell
.\Create-ServerVMs.ps1 -BatchSize 2 -WaitForInstall
```

## How it works

1. Reads the config and fills the XML template with each VM's image index, computer name, and password.
2. Packs the result as `autounattend.xml` into a small ISO.
3. Creates a Generation 2 VM with static memory, a blank disk, the Windows ISO, and the answer-file ISO.
4. Starts the VMs in batches and presses Enter automatically to get past "Press any key to boot from DVD".
5. Windows Setup finds the answer file, installs, and reboots on its own.

VMs that already exist are skipped, and a failure on one VM does not stop the others.

## Security notes

- The password is stored in plain text in the config and in the temporary answer-file ISO (`%TEMP%\<VMName>-unattend.iso`). Use `-WaitForInstall` so the script deletes the ISOs, or delete them yourself after the installs finish.
- Use this for labs and testing. Change the password after first sign-in, and do not commit real passwords to Git.

## Troubleshooting

| Problem | Likely fix |
|---|---|
| `ISO not found` | Check `isoPath` in the config. |
| Virtual switch error | Check the `switch` name with `Get-VMSwitch`. |
| Setup shows an edition or key screen | `imageIndex` does not match your ISO. Check it with `Get-WindowsImage`. Retail ISOs may also need a product key. |
| VM sits at "Press any key to boot from DVD" | The key presses missed the prompt. Click into the VM and press a key, or delete the VM and run again. |
| Setup stalls near the end | The password may not meet Windows complexity rules (8+ characters, 3 of 4 types). |
| Computer name error | Windows names are limited to 15 characters. Set `computerName` for long VM names. |
| Not enough memory | Memory is static, so lower `-BatchSize` or reduce `memoryGB`. |

# VBR Azure Repository & Protected VM Inventory

`vbr-vbazprotectedvminfo.ps1` lists all Azure object storage repositories, including external repositories, on one or more Veeam Backup & Replication (VBR) servers. It also lists the workloads that have backup data in those repositories, and adds Azure details about the storage accounts and the protected Azure VMs.

> **Disclaimer:** This is a community script. Veeam Software does not provide official support for it. Part of it uses internal, undocumented VBR classes (`[Veeam.Backup.Core.CBackup]::GetAll()`), which may change between VBR versions. Test it in your environment before you rely on its results.

---

## What the script does

### Part 1: Veeam Backup & Replication (repeats for each server)
1. Asks for a VBR server and optional alternative credentials, then connects.
2. Collects all Azure repositories:
   - object storage repositories (Azure Blob, Azure Archive)
   - external repositories (Veeam Backup for Microsoft Azure, Veeam Data Cloud Vault)
3. Collects every workload with backup data in these repositories, directly or through a Scale-Out Backup Repository tier. Each workload is classified as **VM**, **Agent** or **Azure VM**.
4. Asks whether to connect to another VBR server. New results are appended to the same CSV files.

### Part 2: Microsoft Azure
1. Asks whether to start the Azure part now. If you decline, it prints the exact command to run it later.
2. Connects to Azure, or reuses an existing connection, and scans all enabled subscriptions.
3. Finds the storage account behind each repository by its container name and adds the account details to the repository CSV.
4. Creates a CSV of all protected Azure VMs, with disk sizes and a region check against the repository.
5. Asks whether to disconnect from Azure or keep the connection for the next run.

The Azure part runs in a **separate PowerShell process** by default. This keeps the Veeam and Az modules out of the same session, because they ship conflicting versions of shared assemblies.

---

## Requirements

| Component | Requirement |
|---|---|
| PowerShell | Windows PowerShell 5.1 or PowerShell 7.x |
| Veeam | Veeam Backup & Replication console with the `Veeam.Backup.PowerShell` module, v12 or later |
| Az modules | `Az.Accounts`, `Az.Storage`, `Az.Compute`. If they are missing, the script offers to install them (CurrentUser scope). |
| VBR permissions | A user that can read the backup infrastructure and backups, for example Veeam Backup Viewer or higher |
| Azure permissions | **Reader** on the subscriptions that hold the storage accounts and VMs. Container names are read through the management plane (`Get-AzRmStorageContainer`), so no data-plane access is needed. |

At startup the script checks all modules before asking any questions.

---

## Usage

```powershell
# Full run: Veeam part, then Azure part
.\vbr-vbazprotectedvminfo.ps1

# Choose the output folder and the Entra ID tenant
.\vbr-vbazprotectedvminfo.ps1 -OutputFolder 'D:\Reports' -TenantId '00000000-0000-0000-0000-000000000000'

# Veeam part only
.\vbr-vbazprotectedvminfo.ps1 -Phase Veeam

# Azure part only, for the CSV files of an earlier run (the script prints this command when you skip the Azure part)
.\vbr-vbazprotectedvminfo.ps1 -Phase Azure `
    -RunFolder     'C:\Scripts\VBR-AzureRepoReport_20261111_170358' `
    -Timestamp     20261111_170358 `
    -RepositoryCsv 'C:\Scripts\VBR-AzureRepoReport_20261111_170358\VBR-AzureRepositories_20261111_170358.csv' `
    -WorkloadCsv   'C:\Scripts\VBR-AzureRepoReport_20261111_170358\VBR-AzureRepoWorkloads_20261111_170358.csv' `
    -LogFile       'C:\Scripts\VBR-AzureRepoReport_20261111_170358\VBR-AzureRepoReport_20261111_170358.log'
```

### Parameters

| Parameter | Description |
|---|---|
| `-OutputFolder` | Parent folder for the output. Defaults to the script folder. |
| `-Phase` | `All` (default), `Veeam` or `Azure`. |
| `-TenantId` | Optional Entra ID tenant for `Connect-AzAccount`. |
| `-RepositoryCsv`, `-WorkloadCsv` | Existing CSV files to use with `-Phase Azure`. |
| `-RunFolder`, `-Timestamp`, `-LogFile` | Continue an earlier run: same folder, same timestamp, same log file. |
| `-AzureInSameSession` | Run the Azure part in the current session instead of a separate process. |
| `-ChildProcess` | Internal. Set automatically for the Azure process. |

### Prompts during a run

| Prompt | Default |
|---|---|
| VBR server (FQDN or IP) | required |
| Use alternative credentials? (No = current Windows user) | No |
| Connect to another VBR server? | No |
| Start the Azure data gathering now? | Yes |
| Use the existing Azure connection? (only when one exists) | Yes |
| Search all other storage accounts? (only when a container is not found in the accounts registered in VBR) | No |
| Disconnect from Azure? (No = keep the connection for the next run) | No |

---

## Output

All files from one run go into a subfolder named with the run timestamp:

```
<OutputFolder>\VBR-AzureRepoReport_<yyyyMMdd_HHmmss>\
    VBR-AzureRepositories_<timestamp>.csv
    VBR-AzureRepoWorkloads_<timestamp>.csv
    Azure-ProtectedVMs_<timestamp>.csv
    VBR-AzureRepoReport_<timestamp>.log
    VBR-AzureRepoDiagnostics_<timestamp>.txt      (only written when needed)
```

### `VBR-AzureRepositories_<timestamp>.csv`

| Column | Source | Content |
|---|---|---|
| VBR Server | VBR | VBR server the repository belongs to |
| Repository Name | VBR | Name of the repository |
| Repository Type | VBR | `Object storage (AzureBlob)`, `External (...)`, ... |
| Azure Storage Account | VBR / Azure | Storage account; matched by container name if VBR does not expose it |
| Storage Account Source | VBR / Azure | How the storage account was found |
| Container | VBR | Blob container |
| Repository Path | VBR | `container/folder` |
| Immutability Settings | VBR | `Disabled`, `Enabled (<n> days)` or `Unknown` |
| VBR Registered Storage Accounts | VBR | Storage accounts registered in VBR; used for the container match |
| Repository Id | VBR | VBR repository ID |
| Resource Group | Azure | Resource group of the storage account |
| Primary Region | Azure | Primary Azure region |
| Replication | Azure | `LRS`, `ZRS`, `GRS`, `RA-GRS`, `GZRS`, `RA-GZRS` |
| Default Access Tier | Azure | `Hot`, `Cool`, `Cold`, `N/A (Premium)` |
| Performance Tier | Azure | `Standard`, `Premium` |
| Subscription / Subscription ID | Azure | Subscription of the storage account |

### `VBR-AzureRepoWorkloads_<timestamp>.csv`

| Column | Content |
|---|---|
| VBR Server | VBR server |
| Repository Name | Azure repository that holds the backup data |
| Workload Name | VM, computer or Azure VM name |
| Workload Type | `VM`, `Agent`, `Azure VM` (plug-in backups: `Other (Plug-in: ...)`) |
| Backup Name | Name of the backup in VBR |
| Placement | `Direct` or `SOBR '<name>' <Performance/Capacity/Archive> tier` |

### `Azure-ProtectedVMs_<timestamp>.csv`

There is one line per Azure VM and repository.

| Column | Content |
|---|---|
| Name | Azure VM name |
| Resource Group | Resource group of the VM (`Not found` if the VM no longer exists or is not accessible) |
| Region | Azure region of the VM |
| Total Disk Size (GB) | Sum of the OS disk and data disks |
| Disk Count | Number of attached disks |
| Subscription / Subscription ID | Subscription of the VM |
| VBR Server / VBR Repository | Where the backup data is stored |
| Repository Region | `Primary Region` from the repository CSV (not looked up in Azure again) |
| Region Check | `OK` or a `WARNING: ...` note if the VM region and repository region differ or cannot be compared |

### Log file
Each message is written to the console in colour (info grey, success green, warning yellow, error red) and to the log file with a timestamp. The run ends with a summary of errors and warnings.

### Diagnostics file
If VBR does not expose a value the script needs, the object's property tree goes to the diagnostics file. Examples are a storage account that is not exposed, or a backup without readable objects. Include this file when you report a problem.

---

## How some values are found

- **Storage account:** VBR usually doesn't expose the storage account on Azure repository objects. The Azure part looks for the repository's container first in the storage accounts registered in VBR. If you agree, it then searches all other storage accounts in the accessible subscriptions. A container name found in more than one account is shown as `Ambiguous`.
- **Veeam Data Cloud Vault:** vault repositories are detected by name and type. Their storage is not in your own subscriptions, so no Azure details are added.
- **Backups:** `Get-VBRBackup` does not return imported or external backups, such as those from Veeam Backup for Microsoft Azure. The script also reads all backups from the configuration database and removes duplicates by backup ID.
- **Workload names:** names are read from backup objects, object-in-backup (OIB) entries, child backups or restore points. For encrypted or imported backups with no object entries, the VM name comes from the child backup name (`<VM name> Backup`).
- **Azure VMs:** VMs are matched by name across all accessible subscriptions. If the same name exists more than once, all matches are listed and a warning is logged.

---

## Known limitations

- The Veeam Backup for Microsoft Azure appliance that created a backup is **not** reported. VBR does not reliably record it for imported backups.
- Matching the storage account by container name can be ambiguous when several storage accounts have a container with the same name.
- Azure VMs that were deleted, renamed or are in subscriptions you cannot access show `Not found`.
- Immutability is read from the repository object. External repositories do not expose it and show `Unknown`.

---

## License

MIT License

Copyright (c) 2026 David Bewernick

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

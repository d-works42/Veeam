# VB365 Random Item Restore

Automated recoverability test for Veeam Backup for Microsoft 365 (VB365).

> This script was created with the assistance of an AI coding tool (Claude/Anthropic).
> Review and test it in a lab environment before relying on it in production; provided
> as-is, with no warranty.

## What it does

For one or more organizations backed up by VB365, the script:

1. Connects to the VB365 server and opens the latest restore point per organization.
2. For each selected workload (Exchange, OneDrive, SharePoint, Teams), discovers
   mailboxes/users/sites/teams and picks a configurable number of **distinct random
   items**, spread round-robin across different mailboxes/users/sites/teams rather
   than piling up on whichever one happens to have the most content.
3. Exports/saves a copy of each sampled item to disk (Exchange items as `.pst` files,
   everything else as loose files) — this proves the backup is actually recoverable,
   without touching production data. No in-place restore is performed anywhere.
4. Writes a CSV report (one row per sampled item, plus a row per organization noting
   which restore point — backup time, job ID, repository ID — was used) and exits
   with a non-zero code if any sample failed.

Only one restore session per workload per organization is opened, regardless of how
many samples are requested; all samples for that workload/organization are drawn from
that single session.

## Requirements

- PowerShell 7
- 64-bit Outlook installed on the machine running this script (used by the Exchange
  item export/PST path)
- The VB365 PowerShell module (`Veeam.Archiver.PowerShell.dll`), from the VB365
  console/management server installation

## Usage

```powershell
# Run against localhost using the current Windows session (no -Credential needed)
./vb365-RandomItemRestore.ps1 -ExportPath D:\RecoverabilityTest

# Run against a remote server, a specific organization, and specific workloads
./vb365-RandomItemRestore.ps1 -Server vbo365.contoso.local -Credential $cred `
    -OrganizationName "Contoso*" -Workload Exchange,OneDrive -SampleSize 3 `
    -ExportPath D:\RecoverabilityTest

# Run everything except Teams
./vb365-RandomItemRestore.ps1 -ExportPath D:\RecoverabilityTest -ExcludeWorkload Teams
```

### Parameters

| Parameter | Description | Default |
|---|---|---|
| `-Server` | VB365 server to connect to. | `localhost` |
| `-Port` | VB365 server port. | `9191` |
| `-Credential` | Credential for the VB365 server. Not required against `localhost` — the current Windows session is used instead. | (none) |
| `-OrganizationName` | Organization name filter, wildcards supported. | `*` (all organizations) |
| `-ExportPath` | Root folder under which exported items and the CSV report are written. Each run creates its own timestamped subfolder here (`yyyyMMdd-HHmmss`), so repeated runs never overwrite or mix with each other's output. | *(mandatory)* |
| `-Workload` | One or more of `Exchange`, `OneDrive`, `SharePoint`, `Teams`. | all four |
| `-ExcludeWorkload` | One or more of `Exchange`, `OneDrive`, `SharePoint`, `Teams` to skip, even if included in `-Workload` (e.g. `-ExcludeWorkload Teams` to run everything except Teams). | none excluded |
| `-SampleSize` | Number of distinct random items to test per workload per organization (fewer are sampled if that many don't exist). | `1` |
| `-ArchiverDllPath` | Path to `Veeam.Archiver.PowerShell.dll`. Importing by DLL path avoids the PowerShell 7 Windows PowerShell compatibility layer, which is known to silently drop `-Confirm:$false` on some VB365 cmdlets. | `C:\Program Files\Veeam\Backup365\Veeam.Archiver.PowerShell.dll` |

## Output

- Every run creates its own subfolder `<ExportPath>\<yyyyMMdd-HHmmss>\`, so repeated
  runs never overwrite or mix with each other's output.
- Within that, exported items land under `<Workload>\<Organization>\...`.
- A CSV report `RandomItemRestore-Report-<timestamp>.csv` is written there too, with
  one row per sampled item (`Workload`, `Organization`, `Target`, `Item`,
  `Destination`, `Status`, `Detail`) plus a `RestorePoint` info row per organization.
- The script exits with code `1` if any sampled item failed, and throws immediately if
  `-ExcludeWorkload` excludes every workload that would otherwise have run.

## Known limitations

- **SharePoint system libraries**: `VESPDocumentLibrary` exposes no `Hidden`/`IsHidden`
  property, so well-known system libraries (Site Pages, Style Library, Site Assets,
  Form Templates, Site Collection Images, Teams Wiki Data, Preservation Hold Library)
  are excluded by name/URL pattern instead of a real flag. A renamed or unusual system
  library could slip through.
- Sampling relies on the object model exposed by the installed VB365 PowerShell module
  version; cmdlet parameter sets were verified against a specific VB365 v8 environment
  and may differ on other versions.

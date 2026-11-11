# Get Azure Storage Account Info
PowerShell script that connects to Microsoft Azure and exports the location, redundancy and access tier of Azure storage accounts to a CSV file.

## Important note:
Please be aware that the provided code is only an example and is not officially tested and supported by Veeam or Microsoft. Use it at your own risk and test it in a lab environment first.

## Features
- Checks if the required PowerShell modules are installed and loaded, and asks before installing or importing them.
- Reads storage accounts either
  - from a **CSV file** with storage account names (only these accounts are looked up), or
  - **live from Azure** (all storage accounts).
- Lists all enabled subscriptions and lets you select **one subscription** or **all subscriptions**.
- Reuses an existing Azure session if available, otherwise opens the Azure sign-in.
- Writes the result to a CSV file named with the current timestamp.

## Output
File: `<yyyyMMdd_HHmmss>_AzureStorageAccounts.csv`

| Column | Description | Example |
|---|---|---|
| StorageAccountName | Name of the storage account | `stbackup01` |
| ResourceGroup | Resource group of the storage account | `rg-backup` |
| Region | Primary Azure region | `westeurope` |
| Redundancy | Replication setting | `LRS`, `ZRS`, `GRS`, `RA-GRS`, `GZRS`, `RA-GZRS` |
| AccessTier | Default access tier of the account | `Hot`, `Cool`, `Cold`, `N/A (Premium)` |
| Performance | Performance tier | `Standard`, `Premium` |
| Kind | Storage account kind | `StorageV2`, `BlobStorage` |
| SubscriptionName | Subscription of the storage account | `Production` |
| SubscriptionId | Subscription ID | `00000000-0000-...` |

Warnings and errors are written to `<yyyyMMdd_HHmmss>_errors.log`. This file is only created if a warning or error occurs.

## Requirements
- PowerShell 7 or later
- PowerShell modules from the PowerShell Gallery (the script offers to install them):
  - `Az.Accounts`
  - `Az.Storage`
- An Azure account with at least **Reader** permission on the subscriptions in scope

## Usage
Run the script in an interactive PowerShell 7 console:
```
pwsh -File .\get-azurestoragelocation.ps1
```

Use a CSV file with storage account names and skip the "CSV or live" question:
```
pwsh -File .\get-azurestoragelocation.ps1 -InputCsv .\accounts.csv
```

Use `;` as delimiter for input and output (e.g. Excel with German/European regional settings) and write the output to a different folder:
```
pwsh -File .\get-azurestoragelocation.ps1 -Delimiter ';' -OutputRoot C:\Temp\Reports
```

### Parameters
| Parameter | Description | Default |
|---|---|---|
| `-InputCsv` | Path to a CSV file with storage account names. If set, the "CSV or live" question is skipped. | asked at runtime |
| `-OutputRoot` | Folder for the output CSV and the error log. | script folder |
| `-Delimiter` | CSV delimiter for input and output. | `,` |

### Input CSV format
The storage account names are taken from a column named `StorageAccountName`, `StorageAccount`, `AccountName` or `Name`:
```
StorageAccountName
stbackup01
starchive02
```

If none of these columns exists, the first value of every line is used, so a plain list without header works as well:
```
stbackup01
starchive02
```

Names are not case-sensitive and duplicates are removed. Storage accounts from the CSV file that are not found in the selected subscriptions are reported as a warning on the screen and in the error log.

## Important to know
- **Archive** is not a storage account setting. Azure only allows Hot, Cool or Cold as the default access tier of a storage account; Archive is set per blob. The `AccessTier` column therefore never shows Archive.
- Premium storage accounts (e.g. `BlockBlobStorage`, `FileStorage`) have no access tier and are shown as `N/A (Premium)`.
- Only subscriptions in state **Enabled** are listed.

## License

MIT License

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

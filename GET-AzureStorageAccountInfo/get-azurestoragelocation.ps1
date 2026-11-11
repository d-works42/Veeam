<#
.SYNOPSIS
    Exports location, redundancy and access tier of Azure storage accounts to a CSV file.

.DESCRIPTION
    Connects to Microsoft Azure and reads storage accounts either
      - from a CSV file with storage account names (only these accounts are looked up), or
      - live from Azure (all storage accounts).
    The scope can be one selected subscription or all enabled subscriptions.

    For each storage account the following is written to <timestamp>_AzureStorageAccounts.csv:
      StorageAccountName, ResourceGroup, Region, Redundancy (LRS, ZRS, GRS, RA-GRS, GZRS, RA-GZRS),
      AccessTier (Hot, Cool, Cold; Premium accounts have no access tier),
      plus Performance, Kind, SubscriptionName and SubscriptionId for reference.

    Note: 'Archive' is not a storage account setting. Azure only allows Hot, Cool or Cold as the
    default access tier of an account; Archive is set per blob.

    Errors and warnings are written to <timestamp>_errors.log (only created if something goes wrong).

.PARAMETER InputCsv
    Optional path to a CSV file with storage account names. If set, the "CSV or live" question is
    skipped. The names are taken from a column named StorageAccountName, StorageAccount, AccountName
    or Name; if none of these exists, the first value of every line is used (file without header).

.PARAMETER OutputRoot
    Folder for the output CSV and the error log. Default: the script folder.

.PARAMETER Delimiter
    CSV delimiter for input and output. Default ','. Use ';' for Excel with German/European regional settings.

.EXAMPLE
    pwsh -File .\get-azurestoragelocation.ps1

.EXAMPLE
    pwsh -File .\get-azurestoragelocation.ps1 -InputCsv .\accounts.csv -Delimiter ';'

.NOTES
    Requires: PowerShell 7 or later
              Az.Accounts, Az.Storage (PowerShell Gallery)
#>

[CmdletBinding()]
param(
    [string]$InputCsv,
    [string]$OutputRoot,
    [char]$Delimiter = ','
)

#region ---------- PowerShell version check ----------

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This script requires PowerShell 7 or later. Current version: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))." -ForegroundColor Red
    Write-Host 'Please start it with pwsh, e.g.:  pwsh -File .\get-azurestoragelocation.ps1' -ForegroundColor Red
    exit 1
}

#endregion

#region ---------- Setup: timestamp, output paths, helper functions ----------

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
if (-not (Test-Path -Path $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$OutputCsv    = Join-Path $OutputRoot "$($Timestamp)_AzureStorageAccounts.csv"
$ErrorLogFile = Join-Path $OutputRoot "$($Timestamp)_errors.log"
$ErrorCount   = 0

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info',
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Level) {
        'Info'    { Write-Host "[$time] $Message" }
        'Warning' { Write-Host "[$time] WARNING: $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "[$time] ERROR: $Message" -ForegroundColor Red }
    }
    if ($Level -ne 'Info') {
        $script:ErrorCount++
        $line = "[$time] [$($Level.ToUpper())] $Message"
        if ($ErrorRecord) {
            $line += "`r`n    Exception: $($ErrorRecord.Exception.Message)"
            if ($ErrorRecord.InvocationInfo) {
                $line += "`r`n    At: $($ErrorRecord.InvocationInfo.PositionMessage -replace "`n", "`n    ")"
            }
        }
        Add-Content -Path $ErrorLogFile -Value $line -Encoding UTF8
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question)
    while ($true) {
        $raw = Read-Host "$Question [Y/N]"
        if ($null -eq $raw) { throw 'No interactive input available (Read-Host returned nothing). Run the script in an interactive console.' }
        $answer = $raw.Trim().ToUpper()
        if ($answer -in 'Y', 'YES', 'J', 'JA') { return $true }
        if ($answer -in 'N', 'NO', 'NEIN')     { return $false }
    }
}

# Asks for a number between 1 and $Max and returns it.
function Read-Number {
    param([Parameter(Mandatory)][string]$Question, [Parameter(Mandatory)][int]$Max)
    while ($true) {
        $raw = Read-Host "$Question (1-$Max)"
        if ($null -eq $raw) { throw 'No interactive input available (Read-Host returned nothing). Run the script in an interactive console.' }
        $number = 0
        if ([int]::TryParse($raw.Trim(), [ref]$number) -and $number -ge 1 -and $number -le $Max) { return $number }
        Write-Host "Please enter a number between 1 and $Max." -ForegroundColor Yellow
    }
}

# Reads storage account names from a CSV file. Returns a unique, lower-case list.
function Import-StorageAccountNames {
    param([Parameter(Mandatory)][string]$Path)

    $knownColumns = 'StorageAccountName', 'StorageAccount', 'AccountName', 'Name'
    $lines        = @(Get-Content -Path $Path -Encoding UTF8 -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return @() }

    $header = @($lines[0].Split($Delimiter) | ForEach-Object { $_.Trim().Trim('"') })
    $column = $knownColumns | Where-Object { $_ -in $header } | Select-Object -First 1

    if ($column) {
        Write-Log "Reading storage account names from column '$column'."
        $names = Import-Csv -Path $Path -Delimiter $Delimiter -Encoding UTF8 | ForEach-Object { $_.$column }
    }
    else {
        Write-Log "No column named $($knownColumns -join ' / ') found - using the first value of every line (no header)."
        $names = $lines | ForEach-Object { $_.Split($Delimiter)[0].Trim().Trim('"') }
    }

    return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
             ForEach-Object { $_.Trim().ToLower() } | Sort-Object -Unique)
}

# Splits an Azure SKU like 'Standard_RAGZRS' into performance and a readable redundancy value.
function ConvertFrom-StorageSku {
    param([string]$SkuName)
    $redundancyMap = @{
        'LRS'    = 'LRS'
        'ZRS'    = 'ZRS'
        'GRS'    = 'GRS'
        'RAGRS'  = 'RA-GRS'
        'GZRS'   = 'GZRS'
        'RAGZRS' = 'RA-GZRS'
    }
    $performance, $redundancy = "$SkuName".Split('_', 2)
    if ($redundancy -and $redundancyMap.ContainsKey($redundancy.ToUpper())) {
        $redundancy = $redundancyMap[$redundancy.ToUpper()]
    }
    [PSCustomObject]@{
        Performance = $performance
        Redundancy  = if ($redundancy) { $redundancy } else { $SkuName }
    }
}

Write-Log "Run timestamp: $Timestamp"

#endregion

#region ---------- Module check ----------

$RequiredModules = 'Az.Accounts', 'Az.Storage'

foreach ($name in $RequiredModules) {
    if (Get-Module -Name $name) {
        Write-Log "Module '$name' is already loaded."
        continue
    }

    $installed = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $installed) {
        if (Read-YesNo "Module '$name' is not installed. Install it from the PowerShell Gallery (CurrentUser scope)?") {
            try {
                Install-Module -Name $name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
                Write-Log "Module '$name' installed."
                $installed = $true
            }
            catch { Write-Log "Installation of module '$name' failed." -Level Error -ErrorRecord $_ }
        }
    }

    $loaded = $false
    if ($installed) {
        if (Read-YesNo "Module '$name' is not loaded. Import it now?") {
            try {
                Import-Module -Name $name -ErrorAction Stop -WarningAction SilentlyContinue
                Write-Log "Module '$name' imported."
                $loaded = $true
            }
            catch { Write-Log "Import of module '$name' failed." -Level Error -ErrorRecord $_ }
        }
    }

    if (-not $loaded) {
        Write-Log "Required module '$name' is not available. The script cannot continue." -Level Error
        Write-Host "Error log: $ErrorLogFile"
        exit 1
    }
}

#endregion

#region ---------- Source: CSV file or live from Azure ----------

$FilterNames = $null   # $null = all storage accounts (live); otherwise HashSet of names from the CSV

if ([string]::IsNullOrWhiteSpace($InputCsv)) {
    Write-Host ''
    Write-Host 'Which storage accounts should be read?'
    Write-Host '  1) Import storage account names from a CSV file'
    Write-Host '  2) Read all storage accounts live from Azure'
    if ((Read-Number -Question 'Select' -Max 2) -eq 1) {
        do {
            $InputCsv = (Read-Host 'Path to the CSV file').Trim().Trim('"').Trim("'")
            if (-not (Test-Path -Path $InputCsv -PathType Leaf)) {
                Write-Host "File '$InputCsv' not found." -ForegroundColor Yellow
                $InputCsv = $null
            }
        } until ($InputCsv)
    }
}

if ($InputCsv) {
    try {
        $names = Import-StorageAccountNames -Path $InputCsv
    }
    catch {
        Write-Log "Could not read CSV file '$InputCsv'. The script cannot continue." -Level Error -ErrorRecord $_
        Write-Host "Error log: $ErrorLogFile"
        exit 1
    }
    if ($names.Count -eq 0) {
        Write-Log "No storage account names found in '$InputCsv'. The script cannot continue." -Level Error
        Write-Host "Error log: $ErrorLogFile"
        exit 1
    }
    $FilterNames = [System.Collections.Generic.HashSet[string]]::new([string[]]$names)
    Write-Log "$($FilterNames.Count) storage account name(s) imported from '$InputCsv'."
}
else {
    Write-Log 'All storage accounts will be read live from Azure.'
}

#endregion

#region ---------- Connect to Azure ----------

try {
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($context -and $context.Account -and (Read-YesNo "Already connected to Azure as '$($context.Account.Id)'. Use this connection?")) {
        Write-Log "Using existing Azure connection ($($context.Account.Id))."
    }
    else {
        Connect-AzAccount -ErrorAction Stop | Out-Null
        Write-Log "Connected to Azure as '$((Get-AzContext).Account.Id)'."
    }
}
catch {
    Write-Log 'Connection to Microsoft Azure failed. The script cannot continue.' -Level Error -ErrorRecord $_
    Write-Host "Error log: $ErrorLogFile"
    exit 1
}

#endregion

#region ---------- Subscription scope ----------

try {
    $subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name)
}
catch {
    Write-Log 'Could not read Azure subscriptions. The script cannot continue.' -Level Error -ErrorRecord $_
    Write-Host "Error log: $ErrorLogFile"
    exit 1
}

if ($subscriptions.Count -eq 0) {
    Write-Log 'No enabled subscription found for this account. The script cannot continue.' -Level Error
    Write-Host "Error log: $ErrorLogFile"
    exit 1
}

Write-Host ''
Write-Host "Found $($subscriptions.Count) enabled subscription(s):"
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host ("  {0,3}) {1}  ({2})" -f ($i + 1), $subscriptions[$i].Name, $subscriptions[$i].Id)
}

if ($subscriptions.Count -gt 1) {
    Write-Host ''
    Write-Host 'Which subscriptions are in scope?'
    Write-Host '  1) One selected subscription'
    Write-Host '  2) All subscriptions'
    if ((Read-Number -Question 'Select' -Max 2) -eq 1) {
        $index         = Read-Number -Question 'Number of the subscription' -Max $subscriptions.Count
        $subscriptions = @($subscriptions[$index - 1])
    }
}
Write-Log "Subscriptions in scope: $(($subscriptions | ForEach-Object { $_.Name }) -join ', ')"

#endregion

#region ---------- Read storage accounts ----------

$Results = New-Object System.Collections.Generic.List[object]
$Found   = [System.Collections.Generic.HashSet[string]]::new()

foreach ($sub in $subscriptions) {
    Write-Log "Subscription '$($sub.Name)' ($($sub.Id))"
    try {
        Set-AzContext -Subscription $sub.Id -Tenant $sub.TenantId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Could not switch to subscription '$($sub.Name)'." -Level Error -ErrorRecord $_
        continue
    }

    try {
        $accounts = @(Get-AzStorageAccount -ErrorAction Stop)
    }
    catch {
        Write-Log "Could not read storage accounts of subscription '$($sub.Name)'." -Level Error -ErrorRecord $_
        continue
    }

    $added = 0
    foreach ($sa in $accounts) {
        if ($FilterNames -and -not $FilterNames.Contains($sa.StorageAccountName.ToLower())) { continue }
        try {
            $sku = ConvertFrom-StorageSku -SkuName "$($sa.Sku.Name)"

            # Premium / FileStorage accounts have no access tier
            $accessTier = "$($sa.AccessTier)"
            if ([string]::IsNullOrWhiteSpace($accessTier)) {
                $accessTier = if ($sku.Performance -eq 'Premium') { 'N/A (Premium)' } else { 'N/A' }
            }

            $Results.Add([PSCustomObject]@{
                StorageAccountName = $sa.StorageAccountName
                ResourceGroup      = $sa.ResourceGroupName
                Region             = $sa.PrimaryLocation
                Redundancy         = $sku.Redundancy
                AccessTier         = $accessTier
                Performance        = $sku.Performance
                Kind               = "$($sa.Kind)"
                SubscriptionName   = $sub.Name
                SubscriptionId     = $sub.Id
            })
            [void]$Found.Add($sa.StorageAccountName.ToLower())
            $added++
        }
        catch { Write-Log "Error while processing storage account '$($sa.StorageAccountName)'." -Level Error -ErrorRecord $_ }
    }
    Write-Log "  $added of $($accounts.Count) storage account(s) added."
}

if ($FilterNames) {
    $missing = @($FilterNames | Where-Object { -not $Found.Contains($_) } | Sort-Object)
    if ($missing.Count -gt 0) {
        Write-Log "$($missing.Count) storage account(s) from the CSV file were not found in the selected subscription(s): $($missing -join ', ')" -Level Warning
    }
}

#endregion

#region ---------- Export ----------

Write-Log "Total storage accounts: $($Results.Count)"

if ($Results.Count -gt 0) {
    try {
        $Results | Sort-Object SubscriptionName, StorageAccountName |
            Export-Csv -Path $OutputCsv -NoTypeInformation -Delimiter $Delimiter -Encoding UTF8 -ErrorAction Stop
        Write-Log "Written: $OutputCsv"
    }
    catch { Write-Log "Could not write CSV file '$OutputCsv'." -Level Error -ErrorRecord $_ }
}
else {
    Write-Log 'No storage accounts found - no CSV file written.' -Level Warning
}

if ($ErrorCount -gt 0) {
    Write-Host "$ErrorCount warning(s)/error(s) - see $ErrorLogFile" -ForegroundColor Yellow
}

#endregion

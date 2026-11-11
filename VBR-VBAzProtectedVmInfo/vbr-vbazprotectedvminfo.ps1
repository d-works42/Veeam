<#
.SYNOPSIS
    Inventories Azure object storage repositories (incl. external repositories) across one or
    more Veeam Backup & Replication servers, the workloads stored in them, and enriches the
    result with Azure Storage Account and Azure VM details.

.DESCRIPTION
    Phase 1 (Veeam) - interactive loop:
      * Prompts for a VBR server + credentials and connects.
      * Collects all Azure object storage repositories (Azure Blob, Azure Archive, ...) and all
        Azure external repositories (Veeam Backup for Microsoft Azure).
      * Collects every workload (VM / Agent / Azure VM) with backup data in those repositories,
        directly or through a Scale-Out Backup Repository tier.
      * Asks whether another VBR server should be processed; results are appended to the CSVs.

    Phase 2 (Azure):
      * Connects to Microsoft Azure and scans all accessible subscriptions.
      * Extends the repository CSV with Storage Account details.
      * Creates a CSV with details of all Azure VMs found in the workload CSV.

    The Azure phase runs in a separate PowerShell process by default, so the Veeam and Az
    modules never share one AppDomain (they ship conflicting versions of common assemblies).

    Output (subfolder and file names carry the same timestamp):
      <OutputFolder>\VBR-AzureRepoReport_<timestamp>\
        VBR-AzureRepositories_<timestamp>.csv
        VBR-AzureRepoWorkloads_<timestamp>.csv
        Azure-ProtectedVMs_<timestamp>.csv
        VBR-AzureRepoReport_<timestamp>.log
        VBR-AzureRepoDiagnostics_<timestamp>.txt   (only if needed)

.PARAMETER OutputFolder
    Parent folder; a subfolder 'VBR-AzureRepoReport_<timestamp>' is created in it for all files
    of the run. Defaults to the script folder.

.PARAMETER RunFolder
    Explicit folder for the run's files (used internally for the Azure child process).

.PARAMETER Phase
    All (default) = Veeam phase followed by Azure phase.
    Veeam         = Veeam phase only.
    Azure         = Azure phase only; requires -RepositoryCsv and -WorkloadCsv.

.PARAMETER TenantId
    Optional Entra ID tenant to connect to.

.PARAMETER AzureInSameSession
    Run the Azure phase in the current session instead of a child process.

.EXAMPLE
    .\vbr-vbazprotectedvminfo.ps1

.EXAMPLE
    .\vbr-vbazprotectedvminfo.ps1 -Phase Azure -RepositoryCsv .\VBR-AzureRepositories_20261111_101500.csv -WorkloadCsv .\VBR-AzureRepoWorkloads_20261111_101500.csv

.NOTES
    Requirements:
      * Veeam Backup & Replication PowerShell module (Veeam.Backup.PowerShell), v12 or later
      * Az.Accounts, Az.Storage, Az.Compute  (Install-Module Az -Scope CurrentUser)
    Compatible with Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$OutputFolder,

    [ValidateSet('All', 'Veeam', 'Azure')]
    [string]$Phase = 'All',

    [string]$RepositoryCsv,
    [string]$WorkloadCsv,
    [string]$LogFile,
    [string]$Timestamp,
    [string]$RunFolder,
    [string]$TenantId,
    [switch]$AzureInSameSession,
    [switch]$ChildProcess          # internal: set when the Azure phase runs in the child process
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

#region ---------- Initialisation ----------
if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $OutputFolder = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($Timestamp)) { $Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss' }
# All files of one run go into a subfolder named with the run timestamp
if ([string]::IsNullOrWhiteSpace($RunFolder)) { $RunFolder = Join-Path $OutputFolder "VBR-AzureRepoReport_$Timestamp" }
if (-not (Test-Path -LiteralPath $RunFolder)) {
    New-Item -ItemType Directory -Path $RunFolder -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($LogFile))   { $LogFile = Join-Path $RunFolder "VBR-AzureRepoReport_$Timestamp.log" }
if ([string]::IsNullOrWhiteSpace($RepositoryCsv)) { $RepositoryCsv = Join-Path $RunFolder "VBR-AzureRepositories_$Timestamp.csv" }
if ([string]::IsNullOrWhiteSpace($WorkloadCsv))   { $WorkloadCsv   = Join-Path $RunFolder "VBR-AzureRepoWorkloads_$Timestamp.csv" }
$AzureVmCsv = Join-Path $RunFolder "Azure-ProtectedVMs_$Timestamp.csv"
$DiagFile   = Join-Path $RunFolder "VBR-AzureRepoDiagnostics_$Timestamp.txt"

$script:LogFile = $LogFile
$script:WarningCount = 0
$script:ErrorCount = 0
#endregion

#region ---------- Helper functions ----------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-7}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        'WARN'    { Write-Host $line -ForegroundColor Yellow; $script:WarningCount++ }
        'ERROR'   { Write-Host $line -ForegroundColor Red;    $script:ErrorCount++ }
        default   { Write-Host $line -ForegroundColor Gray }
    }
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    catch { Write-Host "Unable to write to log file '$($script:LogFile)': $($_.Exception.Message)" -ForegroundColor Red }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if ($answer -eq '') { return $Default }
        if ($answer -match '^(y|yes|j|ja)$') { return $true }
        if ($answer -match '^(n|no|nein)$')  { return $false }
        Write-Host 'Please answer Y or N.' -ForegroundColor Yellow
    }
}

# Safely reads a nested property path like 'AzureBlobFolder.Container.Name'.
function Get-PropValue {
    param($Object, [string]$Path)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        try {
            $prop = $current.PSObject.Properties[$part]
            if ($null -eq $prop) { return $null }
            $current = $prop.Value
        }
        catch { return $null }
    }
    return $current
}

# Returns the first non-empty value of a list of candidate property paths.
# The Veeam object model differs slightly between versions and repository types.
function Get-FirstValue {
    param($Object, [string[]]$Paths)
    foreach ($p in $Paths) {
        $v = Get-PropValue -Object $Object -Path $p
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return $null
}

# Properties that are never searched (unrelated objects or slow/sensitive values).
$SkipProps = 'GatewayServer', 'MountServerOptions', 'AzureProxySpec', 'DecryptionKey', 'ProxyAppliance', 'Credentials'

# Searches an object tree (limited depth) for the first property with one of the given names.
# If the property holds an object, its Name is returned.
function Find-NestedValue {
    param($Object, [string[]]$Names, [int]$Depth = 3)
    if ($null -eq $Object -or $Depth -lt 0) { return $null }
    $props = @(); try { $props = @($Object.PSObject.Properties) } catch { return $null }

    foreach ($prop in $props) {
        if ($prop.Name -notin $Names) { continue }
        $v = $null; try { $v = $prop.Value } catch { continue }
        if ($null -eq $v) { continue }
        if ($v -is [string]) { if ($v) { return $v }; continue }
        $n = Get-FirstValue $v @('Name', 'AccountName', 'StorageAccountName')
        if ($n) { return "$n" }
    }
    foreach ($prop in $props) {
        if ($prop.Name -in $SkipProps) { continue }
        $v = $null; try { $v = $prop.Value } catch { continue }
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType] -or $v -is [System.Collections.IEnumerable]) { continue }
        $r = Find-NestedValue -Object $v -Names $Names -Depth ($Depth - 1)
        if ($r) { return $r }
    }
    return $null
}

# Renders an object tree as text lines (for the diagnostics file).
function Get-ObjectTree {
    param($Object, [string]$Indent = '  ', [int]$Depth = 3)
    $lines = @()
    $props = @(); try { $props = @($Object.PSObject.Properties) } catch { return $lines }
    foreach ($prop in $props) {
        if ($prop.Name -in $SkipProps) { $lines += "$Indent$($prop.Name) = <skipped>"; continue }
        $v = $null; try { $v = $prop.Value } catch { $lines += "$Indent$($prop.Name) = <error reading value>"; continue }
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType] -or $Depth -le 0) {
            $lines += "$Indent$($prop.Name) = $v"
        }
        elseif ($v -is [System.Collections.IEnumerable]) {
            $lines += "$Indent$($prop.Name) = [collection, $(@($v).Count) item(s)]"
        }
        else {
            $lines += "$Indent$($prop.Name) [$($v.GetType().FullName)]"
            $lines += Get-ObjectTree -Object $v -Indent "$Indent  " -Depth ($Depth - 1)
        }
    }
    return $lines
}

function Write-Diagnostics {
    param([string]$Title, [string[]]$Lines)
    $text = @('', "===== $Title =====") + $Lines
    try { Add-Content -LiteralPath $DiagFile -Value $text -Encoding UTF8 } catch { }
}

# Calls a .NET method without arguments. If no parameterless overload exists, overloads whose
# parameters are all boolean are tried with $false and $true (e.g. GetLastOibs(bool)).
function Invoke-FlexibleMethod {
    param($Object, [string]$Name)
    $method = $Object.PSObject.Methods[$Name]
    if (-not $method) { throw "$Name(): method not available." }

    $defs = @($method.OverloadDefinitions)
    $hasParameterless = [bool]($defs | Where-Object { $_ -match "\b$Name\(\)" })
    if ($hasParameterless -or -not $defs) { return @($method.Invoke()) }

    $lastError = $null; $invoked = $false
    foreach ($def in $defs) {
        if ($def -notmatch "\b$Name\((.*)\)") { continue }
        $params = @($Matches[1] -split ',\s*' | Where-Object { $_ })
        if ($params.Count -eq 0) { continue }
        if (@($params | Where-Object { $_ -notmatch '^(bool|System\.Boolean)\s' }).Count -gt 0) { continue }
        foreach ($val in $false, $true) {
            try {
                $argList = [object[]](@($val) * $params.Count)
                $result  = @($method.Invoke($argList))
                $invoked = $true
                if ($result.Count -gt 0) { return $result }
            }
            catch { $lastError = $_.Exception.Message }
        }
    }
    if ($invoked) { return @() }
    $msg = "$Name(): no usable overload. Available: $($defs -join ' / ')"
    if ($lastError) { $msg += " Last error: $lastError" }
    throw $msg
}

function Get-SafeName {
    param($Value)
    if ($null -eq $Value) { return '' }
    $n = Get-PropValue -Object $Value -Path 'Name'
    if ($null -ne $n) { return "$n" }
    return "$Value"
}
#endregion

#region ---------- Veeam phase ----------
function Import-VeeamModule {
    if (Get-Module -Name Veeam.Backup.PowerShell) { return }
    try {
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Log 'Veeam Backup & Replication PowerShell module loaded.' -Level SUCCESS
        return
    }
    catch { Write-Log "Import by module name failed: $($_.Exception.Message). Trying console install path." -Level WARN }

    $candidates = @(
        "$env:ProgramFiles\Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1",
        "$env:ProgramFiles\Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell.dll"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            Import-Module $c -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
            Write-Log "Veeam PowerShell module loaded from '$c'." -Level SUCCESS
            return
        }
    }
    throw 'Veeam Backup & Replication PowerShell module not found. Run this script on a machine with the VBR console installed.'
}

function Connect-VbrInteractive {
    $server = ''
    while ($server -eq '') {
        $server = (Read-Host 'Veeam Backup & Replication server (FQDN or IP)').Trim()
        if ($server -eq '') { Write-Host 'A server name is required.' -ForegroundColor Yellow }
    }

    # --- Connect ---
    try {
        if (Get-VBRServerSession -ErrorAction SilentlyContinue) { Disconnect-VBRServer -ErrorAction SilentlyContinue }
        if (Read-YesNo "Use alternative credentials for '$server' (No = current Windows user)?") {
            $cred = Get-Credential -Message "Credentials for VBR server $server"
            Connect-VBRServer -Server $server -Credential $cred -ErrorAction Stop | Out-Null
        }
        else {
            Connect-VBRServer -Server $server -ErrorAction Stop | Out-Null
        }
        Write-Log "Connected to VBR server '$server'." -Level SUCCESS
        return $server
    }
    catch {
        Write-Log "Connection to VBR server '$server' failed: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

function Get-RepoImmutability {
    param($Repo)
    $enabled = Get-FirstValue $Repo @('EnableBackupImmutability', 'BackupImmutabilityEnabled', 'ImmutabilityEnabled',
                                      'EnableImmutability', 'Immutability.Enabled', 'Immutability.IsEnabled')
    $period  = Get-FirstValue $Repo @('ImmutabilityPeriod', 'BackupImmutabilityPeriod', 'ImmutabilityPeriodDays',
                                      'Immutability.Period', 'Immutability.Days')
    if ($null -eq $enabled -and $null -eq $period) { return 'Unknown (not exposed by repository object)' }
    if ($null -ne $enabled -and -not [bool]$enabled) { return 'Disabled' }
    if ($null -ne $period -and "$period" -ne '' -and "$period" -ne '0') { return "Enabled ($period days)" }
    return 'Enabled'
}

# Reads type, container, folder and (if exposed) the storage account of an object storage or
# external repository. VBR usually does NOT expose the storage account on the repository object;
# in that case the Azure phase finds it by matching the container name.
function Get-AzureRepoInfo {
    param($Repo)

    $folderPrefixes = 'AzureBlobFolder', 'AzureArchiveFolder', 'AmazonS3Folder', 'AmazonS3CompatibleFolder',
                      'S3CompatibleFolder', 'GoogleCloudFolder', 'AmazonGlacierFolder', 'Folder'
    $containerPaths = @(); $folderPaths = @()
    foreach ($p in $folderPrefixes) {
        $containerPaths += "$p.Container.Name", "$p.Container", "$p.Bucket.Name", "$p.Bucket"
        $folderPaths    += "$p.Name", "$p.Folder"
    }
    $containerPaths += 'Container.Name', 'Container', 'Bucket.Name', 'Bucket', 'BucketName'
    $folderPaths    += 'FolderName'

    $accountPaths = 'AzureBlobAccount.Name', 'AzureArchiveAccount.Name', 'Account.Name', 'Connection.Account.Name',
                    'Connection.AzureBlobAccount.Name', 'AzureBlobFolder.Container.Account.Name',
                    'StorageAccount.Name', 'StorageAccount', 'StorageAccountName', 'AccountName'

    $type = "$(Get-FirstValue $Repo @('Type'))"
    if (-not $type) { $type = $Repo.GetType().Name -replace '^VBR' -replace 'Repository$' }

    $folderObj = Get-FirstValue $Repo @('Folder', 'AzureBlobFolder', 'AzureArchiveFolder')
    $isAzure = ($type -match 'Azure') -or ($Repo.GetType().Name -match 'Azure') -or
               ("$folderObj" -match 'Azure') -or ($folderObj -and $folderObj.GetType().Name -match 'Azure')

    $container = Get-SafeName (Get-FirstValue $Repo $containerPaths)
    $folder    = Get-SafeName (Get-FirstValue $Repo $folderPaths)

    $account = Get-FirstValue $Repo $accountPaths
    if (-not $account) {
        $account = Find-NestedValue -Object $Repo -Names @('StorageAccountName', 'AccountName', 'StorageAccount',
                                                            'AzureBlobAccount', 'AzureArchiveAccount', 'Account')
    }
    $account = Get-SafeName $account
    $isVault = ("$($Repo.Name)" -match '^vault\b|vdcvault') -or ($type -match 'Vault|DataCloud')

    $source = if ($account) { 'VBR' } elseif ($isVault) { 'Veeam Data Cloud Vault (storage not in own subscriptions)' } else { '' }

    return [pscustomobject]@{
        Type      = $type
        IsAzure   = [bool]$isAzure
        IsVault   = [bool]$isVault
        Container = $container
        Folder    = $folder
        Path      = (@($container, $folder) | Where-Object { $_ }) -join '/'
        Account   = $account
        Source    = $source
    }
}

function Get-WorkloadType {
    param($Backup, [bool]$IsExternal = $false)
    if ($IsExternal) { return 'Azure VM' }   # Azure external repository = Veeam Backup for Microsoft Azure
    $parts = @()
    foreach ($p in @('TypeToString', 'JobType', 'JobTargetType', 'BackupPlatform.Platform', 'Info.JobType')) {
        $v = Get-PropValue -Object $Backup -Path $p
        if ($null -ne $v) { $parts += "$v" }
    }
    $text = $parts -join ' '
    if ($text -match 'Azure')                                                   { return 'Azure VM' }
    if ($text -match 'EpAgent|Endpoint|EEndPoint|Agent|Physical|Linux|Windows|Mac|Unix|Solaris|AIX') { return 'Agent' }
    if ($text -match 'Plugin|RMAN|Oracle|SapHana|HANA|Db2|MSSQL')               { return "Other (Plug-in: $text)" }
    return 'VM'
}

# Returns the protected object names (VM / computer names) of a backup.
# Tries the backup objects/OIBs, then child backups (agents/policies), then the restore points,
# and finally derives the VM name from '<VM name> Backup' for encrypted/imported external backups.
function Get-BackupObjectNames {
    param($Backup)
    $names = @()
    $nameProps = 'Name', 'VmName', 'DisplayName', 'ObjectName', 'HostName'
    $methods   = 'GetObjects', 'GetLastOibs', 'GetObjectOibsAll', 'GetOibs'

    $collect = {
        param($b)
        $found = @()
        foreach ($m in $methods) {
            if (-not $b.PSObject.Methods[$m]) { continue }
            try {
                foreach ($item in @(Invoke-FlexibleMethod -Object $b -Name $m)) {
                    $n = Get-FirstValue $item $nameProps
                    if ($n) { $found += "$n" }
                }
            }
            catch { $script:objProblems += "$($_.Exception.Message)" }
            if ($found) { break }
        }
        if (-not $found -and $b.PSObject.Methods['GetPoints']) {
            try {
                $points = @(Invoke-FlexibleMethod -Object $b -Name 'GetPoints')
                $points = @($points | Sort-Object { Get-FirstValue $_ @('CreationTime') } -Descending | Select-Object -First 3)
                foreach ($pt in $points) {
                    foreach ($pm in 'GetOibs', 'GetObjects', 'GetAllOibs') {
                        if (-not $pt.PSObject.Methods[$pm]) { continue }
                        try {
                            foreach ($item in @(Invoke-FlexibleMethod -Object $pt -Name $pm)) {
                                $n = Get-FirstValue $item $nameProps
                                if ($n) { $found += "$n" }
                            }
                        }
                        catch { $script:objProblems += "Point.$($_.Exception.Message)" }
                        if ($found) { break }
                    }
                }
            }
            catch { $script:objProblems += "$($_.Exception.Message)" }
        }
        return $found
    }

    $script:objProblems = @()
    $names += & $collect $Backup

    if (-not $names) {
        try { foreach ($child in $Backup.FindChildBackups()) { $names += & $collect $child } }
        catch { $script:objProblems += "FindChildBackups(): $($_.Exception.Message)" }
    }
    if (-not $names) {
        try { $names += @(Get-VBRRestorePoint -Backup $Backup -ErrorAction Stop | ForEach-Object { $_.Name }) }
        catch { $script:objProblems += "Get-VBRRestorePoint: $($_.Exception.Message)" }
    }
    $problems = @($script:objProblems | Select-Object -Unique)
    $names = @($names | Where-Object { $_ } | Select-Object -Unique)

    # Imported / encrypted external backups (e.g. Veeam Backup for Microsoft Azure) have no object
    # entries until decrypted, but the per-VM child backups are named '<VM name> Backup'.
    if ($names.Count -eq 0) {
        $candidates = @()
        if (Get-FirstValue $Backup @('IsPolicy')) { try { $candidates = @($Backup.FindChildBackups()) } catch { } }
        else { $candidates = @($Backup) }
        foreach ($c in $candidates) {
            $cName = "$($c.Name)"
            $cType = "$(Get-FirstValue $c @('TypeToString'))"
            $cRepo = "$(Get-FirstValue $c @('RepositoryType'))"
            if ((($cType -match 'Azure|AWS|Amazon|Google|EC2|GCE') -or ($cRepo -match 'External')) -and $cName -match '^(.+?) Backup$') {
                $names += $Matches[1]
            }
        }
        $names = @($names | Where-Object { $_ } | Select-Object -Unique)
        if ($names.Count -gt 0) {
            Write-Log "Backup '$($Backup.Name)': no object entries in VBR (encrypted/imported) - name(s) derived from backup name: $($names -join ', ')"
        }
    }

    if ($names.Count -eq 0) {
        $detail = if ($problems) { " Details: $($problems -join ' | ')" } else { '' }
        Write-Log "No protected objects found in backup '$($Backup.Name)'.$detail Object details written to '$DiagFile'." -Level WARN
        $methodNames = @($Backup.PSObject.Methods | Where-Object { $_.Name -match 'Oib|Object|Point|Storage|Child|Vm' } |
                         ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
        Write-Diagnostics -Title "Backup '$($Backup.Name)' [$($Backup.GetType().FullName)]" -Lines (
            @("  Relevant methods: $methodNames") + (Get-ObjectTree -Object $Backup -Depth 1))
    }
    return $names
}

#--- Veeam Backup for Microsoft Azure policy -----------------------------------------------------
# Name of the Veeam Backup for Microsoft Azure policy that created a backup.
function Get-BackupPolicyName {
    param($Backup, $BackupById)
    $n = "$(Get-FirstValue $Backup @('Info.BackupPolicyName', 'BackupPolicyName'))"
    if ($n) { return $n }
    $parentId = "$(Get-FirstValue $Backup @('ParentBackupId', 'Info.ParentBackupId'))"
    if ($parentId -and $BackupById.Contains($parentId)) { return "$($BackupById[$parentId].Name)" }
    return ''
}

function Invoke-VeeamCollection {
    param([Parameter(Mandatory)][string]$VbrServer)

    #--- Azure object storage repositories --------------------------------------------------
    $repoRows    = New-Object System.Collections.Generic.List[object]
    $azureRepos  = @{}   # Id -> Name
    $externalIds = @{}   # Ids of Azure external repositories

    # Storage accounts registered in VBR - used in the Azure phase to find the account by container name
    $vbrAccountNames = @()
    try {
        $vbrAccountNames = @(Get-VBRAzureBlobAccount -ErrorAction Stop |
                             ForEach-Object { Get-FirstValue $_ @('Name', 'AccountName', 'StorageAccountName') } |
                             Where-Object { $_ } | ForEach-Object { "$_" } | Sort-Object -Unique)
        Write-Log "[$VbrServer] Azure storage accounts registered in VBR: $($vbrAccountNames.Count) ($($vbrAccountNames -join ', '))"
    }
    catch { Write-Log "[$VbrServer] Get-VBRAzureBlobAccount failed: $($_.Exception.Message)" -Level WARN }
    $vbrAccountList = $vbrAccountNames -join ';'

    $sources = @(
        @{ Label = 'Object storage'; External = $false; Cmd = { Get-VBRObjectStorageRepository -ErrorAction Stop } },
        @{ Label = 'External';       External = $true;  Cmd = { Get-VBRExternalRepository -ErrorAction Stop } }
    )
    foreach ($src in $sources) {
        $all = @()
        try { $all = @(& $src.Cmd) }
        catch { Write-Log "[$VbrServer] Reading $($src.Label) repositories failed: $($_.Exception.Message)" -Level WARN; continue }

        $count = 0
        foreach ($r in $all) {
            try {
                $info = Get-AzureRepoInfo -Repo $r
                if (-not $info.IsAzure) { continue }
                $count++
                if (-not $info.Account -and -not $info.IsVault) {
                    Write-Log ("[$VbrServer] Storage account of repository '$($r.Name)' is not exposed by VBR; " +
                               "it will be matched via container '$($info.Container)' in the Azure phase. Object details written to '$DiagFile'.")
                    Write-Diagnostics -Title "Repository '$($r.Name)' [$($r.GetType().FullName)]" -Lines (Get-ObjectTree -Object $r)
                }
                $azureRepos["$($r.Id)"] = $r.Name
                if ($src.External) { $externalIds["$($r.Id)"] = $true }
                $repoRows.Add([pscustomobject]@{
                    'VBR Server'                      = $VbrServer
                    'Repository Name'                 = $r.Name
                    'Repository Type'                 = "$($src.Label) ($($info.Type))"
                    'Azure Storage Account'           = $info.Account
                    'Storage Account Source'          = $info.Source
                    'Container'                       = $info.Container
                    'Repository Path'                 = $info.Path
                    'Immutability Settings'           = Get-RepoImmutability -Repo $r
                    'VBR Registered Storage Accounts' = $vbrAccountList
                    'Repository Id'                   = "$($r.Id)"
                })
            }
            catch { Write-Log "[$VbrServer] Error while reading repository '$($r.Name)': $($_.Exception.Message)" -Level ERROR }
        }
        Write-Log "[$VbrServer] $($src.Label) repositories: $($all.Count) in total, $count in Azure."
    }

    if ($repoRows.Count -gt 0) {
        $repoRows | Export-Csv -LiteralPath $RepositoryCsv -NoTypeInformation -Append -Encoding UTF8
        Write-Log "[$VbrServer] $($repoRows.Count) repositories written to '$RepositoryCsv'." -Level SUCCESS
    }
    else {
        Write-Log "[$VbrServer] No Azure repositories found." -Level WARN
        return
    }

    #--- Map Scale-Out Backup Repositories that use an Azure repository as tier --------------
    $sobrMap = @{}   # SOBR Id -> list of @{RepoId; Tier; SobrName}
    try {
        foreach ($sobr in @(Get-VBRBackupRepository -ScaleOut -ErrorAction Stop)) {
            $tiers = @()
            foreach ($e in @(Get-PropValue $sobr 'Extent'))           { $tiers += ,@($e, 'Performance') }
            foreach ($e in @(Get-PropValue $sobr 'CapacityExtent'))   { $tiers += ,@($e, 'Capacity') }
            foreach ($e in @(Get-PropValue $sobr 'CapacityExtents'))  { $tiers += ,@($e, 'Capacity') }
            foreach ($e in @(Get-PropValue $sobr 'ArchiveExtent'))    { $tiers += ,@($e, 'Archive') }
            foreach ($t in $tiers) {
                if ($null -eq $t[0]) { continue }
                $rid = Get-FirstValue $t[0] @('Repository.Id', 'RepositoryId', 'Id')
                if ($rid -and $azureRepos.ContainsKey("$rid")) {
                    if (-not $sobrMap.ContainsKey("$($sobr.Id)")) { $sobrMap["$($sobr.Id)"] = @() }
                    $sobrMap["$($sobr.Id)"] += [pscustomobject]@{ RepoId = "$rid"; Tier = $t[1]; SobrName = $sobr.Name }
                }
            }
        }
    }
    catch { Write-Log "[$VbrServer] Reading Scale-Out Backup Repositories failed: $($_.Exception.Message)" -Level WARN }

    #--- Workloads ----------------------------------------------------------------------------
    $workloadRows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    # Backups from several sources, de-duplicated by backup ID. Get-VBRBackup does not return
    # all plug-in / external backups (e.g. Veeam Backup for Microsoft Azure), the configuration
    # database API does.
    $backupById = [ordered]@{}
    try {
        foreach ($b in @(Get-VBRBackup -ErrorAction Stop)) { $backupById["$($b.Id)"] = $b }
        Write-Log "[$VbrServer] Backups from Get-VBRBackup: $($backupById.Count)"
    }
    catch { Write-Log "[$VbrServer] Get-VBRBackup failed: $($_.Exception.Message)" -Level ERROR }
    try {
        $before = $backupById.Count
        foreach ($b in @([Veeam.Backup.Core.CBackup]::GetAll())) {
            if (-not $backupById.Contains("$($b.Id)")) { $backupById["$($b.Id)"] = $b }
        }
        Write-Log "[$VbrServer] Additional backups from configuration database: $($backupById.Count - $before)"
    }
    catch { Write-Log "[$VbrServer] [Veeam.Backup.Core.CBackup]::GetAll() failed: $($_.Exception.Message)" -Level WARN }

    $backups = @($backupById.Values)


    Write-Log "[$VbrServer] Analysing $($backups.Count) backups..."
    $azureBackupCount = 0

    foreach ($b in $backups) {
        try {
            # External backups may reference the repository by a different property
            $repoId = "$(Get-FirstValue $b @('RepositoryId', 'Info.RepositoryId'))"
            foreach ($p in 'RepositoryId', 'ExternalRepositoryId', 'TargetRepositoryId', 'Info.RepositoryId') {
                $v = Get-FirstValue $b @($p)
                if ($v -and ($azureRepos.ContainsKey("$v") -or $sobrMap.ContainsKey("$v"))) { $repoId = "$v"; break }
            }

            $targets = @()
            if ($azureRepos.ContainsKey($repoId)) {
                $targets += [pscustomobject]@{ RepoId = $repoId; Placement = 'Direct' }
            }
            if ($sobrMap.ContainsKey($repoId)) {
                foreach ($m in $sobrMap[$repoId]) {
                    $targets += [pscustomobject]@{ RepoId = $m.RepoId; Placement = "SOBR '$($m.SobrName)' $($m.Tier) tier" }
                }
            }
            if ($targets.Count -eq 0) { continue }
            $azureBackupCount++

            $type  = Get-WorkloadType -Backup $b -IsExternal ($externalIds.ContainsKey($repoId))
            $names = @(Get-BackupObjectNames -Backup $b)
            if ($names.Count -eq 0) { continue }

            # Policy - Azure VM backups only
            $policy = if ($type -eq 'Azure VM') { Get-BackupPolicyName -Backup $b -BackupById $backupById } else { '' }

            foreach ($t in $targets) {
                foreach ($n in $names) {
                    # parent and child backups both appear in the list -> one row per repository/workload
                    $key = "$($t.RepoId)|$n|$type".ToLower()
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $workloadRows.Add([pscustomobject]@{
                        'VBR Server'      = $VbrServer
                        'Repository Name' = $azureRepos[$t.RepoId]
                        'Workload Name'   = $n
                        'Workload Type'   = $type
                        'Backup Name'     = $b.Name
                        'Placement'       = $t.Placement
                        'VBAz Policy'     = $policy
                    })
                }
            }
        }
        catch { Write-Log "[$VbrServer] Error while processing backup '$($b.Name)': $($_.Exception.Message)" -Level ERROR }
    }
    Write-Log "[$VbrServer] Backups stored in Azure repositories: $azureBackupCount"

    if ($workloadRows.Count -gt 0) {
        $workloadRows | Export-Csv -LiteralPath $WorkloadCsv -NoTypeInformation -Append -Encoding UTF8
        Write-Log "[$VbrServer] $($workloadRows.Count) workload entries written to '$WorkloadCsv'." -Level SUCCESS
    }
    else {
        Write-Log "[$VbrServer] No workloads with backup data in Azure repositories found." -Level WARN
    }
}

function Invoke-VeeamPhase {
    do {
        $vbr = Connect-VbrInteractive
        if ($vbr) {
            try { Invoke-VeeamCollection -VbrServer $vbr }
            catch { Write-Log "[$vbr] Unexpected error: $($_.Exception.Message)" -Level ERROR }
            finally {
                try { Disconnect-VBRServer -ErrorAction SilentlyContinue | Out-Null; Write-Log "Disconnected from '$vbr'." }
                catch { }
            }
        }
    } while (Read-YesNo -Prompt 'Connect to another Veeam Backup & Replication server?' -Default $false)
}
#endregion

#region ---------- Azure phase ----------
function Convert-Replication {
    param([string]$SkuName)
    if (-not $SkuName) { return '' }
    $r = ($SkuName -split '_')[-1]
    switch ($r.ToUpper()) {
        'RAGRS'  { return 'RA-GRS' }
        'RAGZRS' { return 'RA-GZRS' }
        default  { return $r.ToUpper() }
    }
}

# Blob container cache: storage account name (lower case) -> set of container names.
# Uses the management plane (Get-AzRmStorageContainer), so Reader permissions are enough.
$script:AccountContainers = @{}

function Read-AccountContainers {
    param([object[]]$Accounts)
    $todo = @($Accounts | Where-Object { $_ -and $_.Kind -ne 'FileStorage' -and -not $script:AccountContainers.ContainsKey($_.Name.ToLower()) } |
              Sort-Object SubscriptionId)
    if ($todo.Count -eq 0) { return }

    Write-Log "Reading blob containers of $($todo.Count) storage account(s)..."
    $activity = 'Reading blob containers of Azure storage accounts'
    $currentSub = $null; $i = 0
    foreach ($sa in $todo) {
        $i++
        Write-Progress -Id 1 -Activity $activity -Status "$i of $($todo.Count) - $($sa.Name)" -PercentComplete ([int](($i - 1) * 100 / $todo.Count))
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        try {
            if ($sa.SubscriptionId -ne $currentSub) {
                Set-AzContext -Subscription $sa.SubscriptionId -Tenant $sa.TenantId -ErrorAction Stop | Out-Null
                $currentSub = $sa.SubscriptionId
            }
            foreach ($c in @(Get-AzRmStorageContainer -ResourceGroupName $sa.ResourceGroup -StorageAccountName $sa.Name -ErrorAction Stop)) {
                [void]$set.Add($c.Name)
            }
        }
        catch { Write-Log "Could not read blob containers of storage account '$($sa.Name)': $($_.Exception.Message)" -Level WARN }
        $script:AccountContainers[$sa.Name.ToLower()] = $set   # cached also on error -> no retry
    }
    Write-Progress -Id 1 -Activity $activity -Completed
}

# Returns the storage accounts (from the given list) that contain a blob container with this name.
function Find-StorageAccountsByContainer {
    param([string]$Container, [object[]]$Accounts)
    $Accounts = @($Accounts | Where-Object { $_ })
    if (-not $Container -or $Accounts.Count -eq 0) { return @() }
    Read-AccountContainers -Accounts $Accounts
    return @($Accounts | Where-Object {
        $set = $script:AccountContainers[$_.Name.ToLower()]
        $set -and $set.Contains($Container)
    })
}

$AzModules = 'Az.Accounts', 'Az.Storage', 'Az.Compute'

# Checks at start-up that all Az modules are installed (offers installation from the PowerShell
# Gallery). They are only imported in the Azure phase, which by default runs in a separate process.
function Test-AzModules {
    $missing = @($AzModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
    if ($missing.Count -eq 0) {
        Write-Log "Az modules installed: $($AzModules -join ', ')." -Level SUCCESS
        return $true
    }
    Write-Log "Missing PowerShell module(s): $($missing -join ', ')." -Level WARN
    if (-not (Read-YesNo "Install $($missing -join ', ') from the PowerShell Gallery (CurrentUser scope)?" -Default $true)) {
        Write-Log "Required module(s) not installed: $($missing -join ', '). Install with: Install-Module $($missing -join ', ') -Scope CurrentUser" -Level ERROR
        return $false
    }
    foreach ($m in $missing) {
        try {
            Install-Module -Name $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
            Write-Log "Module '$m' installed." -Level SUCCESS
        }
        catch {
            Write-Log "Installation of module '$m' failed: $($_.Exception.Message)" -Level ERROR
            return $false
        }
    }
    return $true
}

function Import-AzModules {
    foreach ($m in $AzModules) {
        try {
            Import-Module $m -ErrorAction Stop -WarningAction SilentlyContinue
            Write-Log "Module '$m' loaded." -Level SUCCESS
        }
        catch {
            Write-Log "Module '$m' could not be loaded: $($_.Exception.Message)" -Level ERROR
            return $false
        }
    }
    return $true
}

$script:AzConnected = $false

# Asks at the end whether the Azure connection should be closed or kept for the next run.
function Close-AzureConnection {
    if (-not $script:AzConnected) { return }
    $account = ''
    try { $account = "$((Get-AzContext).Account.Id)" } catch { }

    if (Read-YesNo "Disconnect from Azure ('$account') now? (No = keep the connection for the next run)" -Default $false) {
        try {
            Disconnect-AzAccount -ErrorAction Stop | Out-Null
            Write-Log "Disconnected from Azure ('$account')." -Level SUCCESS
        }
        catch { Write-Log "Disconnect-AzAccount failed: $($_.Exception.Message)" -Level WARN }
        return
    }

    # The Azure phase normally runs in a child process. The connection survives that process
    # only if Az context autosave is enabled (default: CurrentUser -> saved in the user profile).
    $persisted = $true
    try { $persisted = ("$((Get-AzContextAutosaveSetting -ErrorAction Stop).Mode)" -eq 'CurrentUser') } catch { }
    if ($persisted) {
        Write-Log "Azure connection ('$account') kept open; it is reused by new PowerShell sessions and the next run of this script." -Level SUCCESS
    }
    elseif ($ChildProcess) {
        Write-Log ("Azure context autosave is disabled, so the connection ends with the Azure process. " +
                   "Run 'Enable-AzContextAutosave -Scope CurrentUser' or start the script with -AzureInSameSession to keep it.") -Level WARN
    }
    else {
        Write-Log "Azure connection ('$account') kept open in the current PowerShell session." -Level SUCCESS
    }
}

function Invoke-AzurePhase {
    if (-not (Test-AzModules)) { return }
    if (-not (Import-AzModules)) { return }

    $repoData = @(); $workloadData = @()
    if (Test-Path -LiteralPath $RepositoryCsv) { $repoData = @(Import-Csv -LiteralPath $RepositoryCsv) }
    else { Write-Log "Repository CSV '$RepositoryCsv' not found." -Level WARN }
    if (Test-Path -LiteralPath $WorkloadCsv) { $workloadData = @(Import-Csv -LiteralPath $WorkloadCsv) }
    else { Write-Log "Workload CSV '$WorkloadCsv' not found." -Level WARN }

    $azureVmRows    = @($workloadData | Where-Object { $_.'Workload Type' -eq 'Azure VM' })
    $wantedVms      = @($azureVmRows | ForEach-Object { $_.'Workload Name' } | Where-Object { $_ } | Sort-Object -Unique)

    if ($repoData.Count -eq 0 -and $wantedVms.Count -eq 0) {
        Write-Log 'No storage accounts or Azure VMs to look up in Azure.' -Level WARN
        return
    }

    # Reuse an existing Azure connection (e.g. kept open by a previous run) if wanted
    $reused = $false
    $ctx = $null
    try { $ctx = Get-AzContext -ErrorAction SilentlyContinue } catch { }
    if ($ctx -and $ctx.Account -and (-not $TenantId -or "$($ctx.Tenant.Id)" -eq $TenantId)) {
        if (Read-YesNo "Already connected to Azure as '$($ctx.Account.Id)' (tenant $($ctx.Tenant.Id)). Use this connection?" -Default $true) {
            $reused = $true
            Write-Log "Using existing Azure connection of '$($ctx.Account.Id)'." -Level SUCCESS
        }
    }

    $subs = $null
    for ($attempt = 1; $attempt -le 2 -and $null -eq $subs; $attempt++) {
        if (-not $reused) {
            Write-Log 'Connecting to Microsoft Azure...'
            try {
                if ($TenantId) { Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null }
                else           { Connect-AzAccount -ErrorAction Stop | Out-Null }
                Write-Log "Connected to Azure as '$((Get-AzContext).Account.Id)'." -Level SUCCESS
            }
            catch {
                Write-Log "Connect-AzAccount failed: $($_.Exception.Message)" -Level ERROR
                return
            }
        }
        $script:AzConnected = $true

        try {
            $subs = if ($TenantId) { @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop) } else { @(Get-AzSubscription -ErrorAction Stop) }
            $subs = @($subs | Where-Object { $_.State -eq 'Enabled' })
        }
        catch {
            if ($reused) {
                # e.g. expired token of the kept connection -> log in again once
                Write-Log "Existing Azure connection is not usable ($($_.Exception.Message)); logging in again." -Level WARN
                $reused = $false
            }
            else {
                Write-Log "Get-AzSubscription failed: $($_.Exception.Message)" -Level ERROR
                return
            }
        }
    }
    if ($null -eq $subs) { return }
    Write-Log "Scanning $($subs.Count) enabled subscriptions."

    $saIndex = @{}   # storage account name (lower) -> info
    $vmIndex = @{}   # vm name (lower) -> list of info

    foreach ($sub in $subs) {
        try { Set-AzContext -SubscriptionId $sub.Id -TenantId $sub.TenantId -ErrorAction Stop | Out-Null }
        catch { Write-Log "Cannot switch to subscription '$($sub.Name)': $($_.Exception.Message)" -Level WARN; continue }

        if ($repoData.Count -gt 0) {
            try {
                foreach ($sa in @(Get-AzStorageAccount -ErrorAction Stop)) {
                    $key = $sa.StorageAccountName.ToLower()
                    $perf = "$($sa.Sku.Tier)"
                    $tier = if ($perf -eq 'Premium') { 'N/A (Premium)' } elseif ($sa.AccessTier) { "$($sa.AccessTier)" } else { 'N/A' }
                    $saIndex[$key] = [pscustomobject]@{
                        Name           = $sa.StorageAccountName
                        Kind           = "$($sa.Kind)"
                        TenantId       = $sub.TenantId
                        ResourceGroup  = $sa.ResourceGroupName
                        Region         = $sa.PrimaryLocation
                        Replication    = Convert-Replication "$($sa.Sku.Name)"
                        AccessTier     = $tier
                        Performance    = $perf
                        Subscription   = $sub.Name
                        SubscriptionId = $sub.Id
                    }
                }
            }
            catch { Write-Log "Get-AzStorageAccount failed in subscription '$($sub.Name)': $($_.Exception.Message)" -Level WARN }
        }

        if ($wantedVms.Count -gt 0) {
            try {
                $vms = @(Get-AzVM -ErrorAction Stop | Where-Object { $wantedVms -contains $_.Name })
                if ($vms.Count -gt 0) {
                    $diskIndex = @{}
                    foreach ($d in @(Get-AzDisk -ErrorAction Stop)) { $diskIndex[$d.Id.ToLower()] = $d }

                    foreach ($vm in $vms) {
                        $disks = @($vm.StorageProfile.OsDisk) + @($vm.StorageProfile.DataDisks) | Where-Object { $_ }
                        $total = 0; $count = 0
                        foreach ($d in $disks) {
                            $count++
                            $size = $null
                            if ($d.ManagedDisk -and $d.ManagedDisk.Id -and $diskIndex.ContainsKey($d.ManagedDisk.Id.ToLower())) {
                                $size = $diskIndex[$d.ManagedDisk.Id.ToLower()].DiskSizeGB
                            }
                            if (-not $size) { $size = $d.DiskSizeGB }
                            if ($size) { $total += [int64]$size }
                            else { Write-Log "Size of disk '$($d.Name)' on VM '$($vm.Name)' unknown." -Level WARN }
                        }
                        $key = $vm.Name.ToLower()
                        if (-not $vmIndex.ContainsKey($key)) { $vmIndex[$key] = @() }
                        $vmIndex[$key] += [pscustomobject]@{
                            Name           = $vm.Name
                            ResourceGroup  = $vm.ResourceGroupName
                            Region         = $vm.Location
                            TotalDiskGB    = $total
                            DiskCount      = $count
                            Subscription   = $sub.Name
                            SubscriptionId = $sub.Id
                        }
                    }
                }
            }
            catch { Write-Log "Reading VMs/disks failed in subscription '$($sub.Name)': $($_.Exception.Message)" -Level WARN }
        }
    }

    Write-Log "Storage accounts found in Azure: $($saIndex.Count)"

    #--- Resolve storage accounts via container name -----------------------------------------
    # VBR usually does not expose the storage account on the repository. Search the container
    # first in the accounts registered in VBR, then (on request) in all other storage accounts.
    $fullScan = $null
    foreach ($row in $repoData) {
        $container = "$(Get-PropValue $row 'Container')"
        $source    = "$(Get-PropValue $row 'Storage Account Source')"
        if ($row.'Azure Storage Account' -or -not $container -or $source -match 'Vault') { continue }

        $regNames = @("$(Get-PropValue $row 'VBR Registered Storage Accounts')" -split ';' |
                      ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
        $registered = @($regNames | ForEach-Object { $saIndex[$_] } | Where-Object { $_ })
        $hits = @(Find-StorageAccountsByContainer -Container $container -Accounts $registered)
        $scope = 'VBR-registered accounts'

        if ($hits.Count -eq 0) {
            $others = @($saIndex.Values | Where-Object { $_.Kind -ne 'FileStorage' -and $regNames -notcontains $_.Name.ToLower() })
            if ($others.Count -gt 0) {
                if ($null -eq $fullScan) {
                    $fullScan = Read-YesNo ("Container '$container' of repository '$($row.'Repository Name')' was not found in the " +
                        "$($registered.Count) storage account(s) registered in VBR. Search all other $($others.Count) storage " +
                        "account(s) of your subscriptions? (can take a while; the answer applies to the rest of this run)")
                }
                if ($fullScan) {
                    $hits = @(Find-StorageAccountsByContainer -Container $container -Accounts $others)
                    $scope = 'all accounts'
                }
            }
        }

        if ($hits.Count -eq 1) {
            $row.'Azure Storage Account' = $hits[0].Name
            $source = "Matched via container name ($scope)"
            Write-Log "Repository '$($row.'Repository Name')': storage account '$($hits[0].Name)' matched via container '$container'." -Level SUCCESS
        }
        elseif ($hits.Count -gt 1) {
            $row.'Azure Storage Account' = ($hits | ForEach-Object { $_.Name }) -join ' | '
            $source = "Ambiguous container name ($scope)"
            Write-Log "Repository '$($row.'Repository Name')': container '$container' exists in several storage accounts: $($row.'Azure Storage Account')" -Level WARN
        }
        $row | Add-Member -NotePropertyName 'Storage Account Source' -NotePropertyValue $source -Force
    }

    #--- Extend repository CSV -----------------------------------------------------------------
    if ($repoData.Count -gt 0) {
        foreach ($row in $repoData) {
            $info = $null; $reason = ''
            $sa = $row.'Azure Storage Account'
            if ($sa -and $sa -notmatch '\|') { $info = $saIndex[$sa.ToLower()] }
            if (-not $info) {
                $source = "$(Get-PropValue $row 'Storage Account Source')"
                $reason = if ($source -match 'Vault')   { 'n/a (Veeam Data Cloud Vault)' }
                          elseif ($sa -match '\|')      { 'Ambiguous storage account' }
                          elseif ($sa)                  { 'Storage account not found in accessible subscriptions' }
                          else                          { 'Storage account unknown (container not found)' }
                $level = if ($source -match 'Vault') { 'INFO' } else { 'WARN' }
                Write-Log "Repository '$($row.'Repository Name')' ($($row.'VBR Server')): $reason." -Level $level
            }
            $vals = [ordered]@{
                'Resource Group'      = if ($info) { $info.ResourceGroup }  else { $reason }
                'Primary Region'      = if ($info) { $info.Region }         else { '' }
                'Replication'         = if ($info) { $info.Replication }    else { '' }
                'Default Access Tier' = if ($info) { $info.AccessTier }     else { '' }
                'Performance Tier'    = if ($info) { $info.Performance }    else { '' }
                'Subscription'        = if ($info) { $info.Subscription }   else { '' }
                'Subscription ID'     = if ($info) { $info.SubscriptionId } else { '' }
            }
            foreach ($k in $vals.Keys) { $row | Add-Member -NotePropertyName $k -NotePropertyValue $vals[$k] -Force }
        }
        $repoData | Export-Csv -LiteralPath $RepositoryCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Repository CSV extended with Azure storage account details: '$RepositoryCsv'." -Level SUCCESS
    }

    #--- Azure VM CSV ----------------------------------------------------------------------------
    if ($wantedVms.Count -gt 0) {
        # Repository region as written to the repository CSV above ('Primary Region' column) - no new Azure lookup
        $repoRegion = @{}   # "<vbr server>|<repository name>" (lower) -> region
        foreach ($r in $repoData) {
            $repoRegion["$($r.'VBR Server')|$($r.'Repository Name')".ToLower()] = "$(Get-PropValue $r 'Primary Region')"
        }

        $vmRows = New-Object System.Collections.Generic.List[object]
        $mismatchCount = 0
        foreach ($name in $wantedVms) {
            # One CSV line per VM and repository, so the region check is unambiguous per line
            $vmRepos = @($azureVmRows | Where-Object { $_.'Workload Name' -eq $name } |
                         Select-Object 'VBR Server', 'Repository Name' -Unique)
            $vmMatches = @($vmIndex[$name.ToLower()] | Where-Object { $_ })
            if ($vmMatches.Count -eq 0) {
                Write-Log "Azure VM '$name' not found in accessible subscriptions (deleted or no access)." -Level WARN
                $vmMatches = @([pscustomobject]@{
                    Name = $name; ResourceGroup = 'Not found'; Region = ''; TotalDiskGB = ''
                    DiskCount = ''; Subscription = ''; SubscriptionId = ''
                })
            }
            elseif ($vmMatches.Count -gt 1) {
                Write-Log "Azure VM name '$name' exists $($vmMatches.Count) times; all matches are listed." -Level WARN
            }

            foreach ($m in $vmMatches) {
                foreach ($vr in $vmRepos) {
                    $rRegion = $repoRegion["$($vr.'VBR Server')|$($vr.'Repository Name')".ToLower()]
                    if (-not $rRegion) { $rRegion = '' }

                    $check = if (-not $m.Region)  { 'WARNING: VM not found in Azure - region not checked' }
                             elseif (-not $rRegion) { 'WARNING: Repository region unknown - region not checked' }
                             elseif (($m.Region -replace '\s').ToLower() -eq ($rRegion -replace '\s').ToLower()) { 'OK' }
                             else { "WARNING: VM region '$($m.Region)' differs from repository region '$rRegion'" }
                    if ($check -match 'differs') {
                        $mismatchCount++
                        Write-Log "Azure VM '$($m.Name)': region '$($m.Region)' differs from region '$rRegion' of repository '$($vr.'Repository Name')' ($($vr.'VBR Server'))." -Level WARN
                    }

                    $vmRows.Add([pscustomobject]@{
                        'Name'                 = $m.Name
                        'Resource Group'       = $m.ResourceGroup
                        'Region'               = $m.Region
                        'Total Disk Size (GB)' = $m.TotalDiskGB
                        'Disk Count'           = $m.DiskCount
                        'Subscription'         = $m.Subscription
                        'Subscription ID'      = $m.SubscriptionId
                        'VBR Server'           = $vr.'VBR Server'
                        'VBR Repository'       = $vr.'Repository Name'
                        'Repository Region'    = $rRegion
                        'Region Check'         = $check
                    })
                }
            }
        }
        if ($mismatchCount -gt 0) { Write-Log "$mismatchCount VM/repository combination(s) with different regions." -Level WARN }
        $vmRows | Export-Csv -LiteralPath $AzureVmCsv -NoTypeInformation -Encoding UTF8
        Write-Log "$($vmRows.Count) Azure VM entries written to '$AzureVmCsv'." -Level SUCCESS
    }
    else {
        Write-Log 'No Azure VM workloads found; Azure VM CSV not created.'
    }
}
#endregion

#region ---------- Main ----------
Write-Log "===== Start (Phase: $Phase) - log file: $LogFile ====="
try {
    #--- Prerequisites: check / load all required modules before anything else ---------------
    # Veeam is loaded first (assembly binding order); the Az modules are only checked here and
    # imported in the Azure phase (separate process by default) to avoid assembly conflicts.
    if ($Phase -in 'All', 'Veeam') {
        Import-VeeamModule
    }
    if ($Phase -eq 'All') {
        if (-not (Test-AzModules)) {
            if (-not (Read-YesNo 'Az modules are not available. Continue with the Veeam part only?' -Default $false)) {
                throw 'Required Az modules are missing.'
            }
            $Phase = 'Veeam'
            Write-Log 'Continuing with the Veeam part only; run the script later with -Phase Azure to add the Azure details.' -Level WARN
        }
        elseif ($AzureInSameSession -and -not (Import-AzModules)) {
            throw 'Az modules could not be loaded.'
        }
    }

    if ($Phase -in 'All', 'Veeam') {
        Invoke-VeeamPhase
    }

    # All VBR servers done - ask whether the Azure data gathering should start now
    if ($Phase -eq 'All') {
        if (-not (Read-YesNo 'All VBR servers processed. Start the Azure data gathering now?' -Default $true)) {
            $Phase = 'Veeam'
            $later = ".\$(Split-Path -Leaf $PSCommandPath) -Phase Azure -RunFolder '$RunFolder' -Timestamp $Timestamp " +
                     "-RepositoryCsv '$RepositoryCsv' -WorkloadCsv '$WorkloadCsv' -LogFile '$LogFile'"
            if ($TenantId) { $later += " -TenantId $TenantId" }
            Write-Log 'Azure data gathering skipped. To run it later, use:'
            Write-Log "  $later"
        }
    }

    if ($Phase -eq 'Azure' -or ($Phase -eq 'All' -and $AzureInSameSession)) {
        try { Invoke-AzurePhase }
        finally { Close-AzureConnection }   # ask whether to keep the Azure connection
    }
    elseif ($Phase -eq 'All') {
        # Run the Azure part in a fresh process to avoid assembly conflicts between Veeam and Az modules.
        Write-Log 'Starting Azure phase in a separate PowerShell process...'
        $exe = (Get-Process -Id $PID).Path
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                     '-Phase', 'Azure', '-OutputFolder', $OutputFolder, '-Timestamp', $Timestamp, '-RunFolder', $RunFolder,
                     '-LogFile', $LogFile, '-RepositoryCsv', $RepositoryCsv, '-WorkloadCsv', $WorkloadCsv, '-ChildProcess')
        if ($TenantId) { $argList += @('-TenantId', $TenantId) }
        & $exe @argList
        if ($LASTEXITCODE -ne 0) { Write-Log "Azure phase process exited with code $LASTEXITCODE." -Level ERROR }
    }
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level ERROR
    exit 1
}

$summaryLevel = if ($script:ErrorCount -gt 0) { 'ERROR' } elseif ($script:WarningCount -gt 0) { 'WARN' } else { 'SUCCESS' }
Write-Log ("===== Finished (Phase: {0}) - {1} error(s), {2} warning(s) =====" -f $Phase, $script:ErrorCount, $script:WarningCount) -Level $summaryLevel
if ($Phase -ne 'Azure') {
    Write-Host ''
    Write-Host "Repository CSV : $RepositoryCsv" -ForegroundColor Cyan
    Write-Host "Workload CSV   : $WorkloadCsv"   -ForegroundColor Cyan
    Write-Host "Azure VM CSV   : $AzureVmCsv"    -ForegroundColor Cyan
    Write-Host "Log file       : $LogFile"       -ForegroundColor Cyan
}
exit 0
#endregion

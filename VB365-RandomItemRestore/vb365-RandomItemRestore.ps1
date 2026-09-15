<#
.SYNOPSIS
    Automated recoverability test for Veeam Backup for Microsoft 365 (VB365).

    This script was created with the assistance of an AI coding tool (Claude/Anthropic).
    Review and test it in a lab environment before relying on it in production; provided
    as-is, with no warranty.

.DESCRIPTION
    Connects to a VB365 server, opens the latest restore point for one or more
    organizations, and for each selected workload (Exchange, OneDrive, SharePoint,
    Teams) picks one or more random backed-up items and exports/saves a copy of
    them to disk. This proves the backup is actually recoverable without touching
    production data (no in-place restore is performed).

    Cmdlet names/parameters verified against the official references:
    - https://helpcenter.veeam.com/docs/vbo365/powershell/veeam_psreference.html?ver=8
    - https://helpcenter.veeam.com/docs/vbo365/explorers_powershell/ (item-level restore cmdlets, VEX/VESP/VEOD/VET prefixes)

    NOTE: SharePoint sampling excludes well-known system libraries (Site Pages, Style
    Library, Site Assets, Form Templates, Site Collection Images, Teams Wiki Data,
    Preservation Hold Library) by name/URL pattern, since VESPDocumentLibrary exposes
    no Hidden/IsHidden property to filter on directly.

    Requirements:
    - PowerShell 7
    - 64-bit Outlook installed on the machine running this script (used by the Exchange item export/PST path)

.PARAMETER Server
    VB365 server to connect to. Default: localhost.

.PARAMETER Port
    VB365 server port. Default: 9191.

.PARAMETER Credential
    Credential used to connect to the VB365 server. Not required when connecting to
    localhost, since the current Windows session is used instead.

.PARAMETER OrganizationName
    Organization name filter (wildcards supported). Default: '*' (all organizations).

.PARAMETER ExportPath
    Root folder under which exported/saved items and the CSV report are written. Each
    run creates its own timestamped subfolder here (yyyyMMdd-HHmmss), so repeated runs
    never overwrite or mix with each other's output.

.PARAMETER Workload
    One or more of: Exchange, OneDrive, SharePoint, Teams. Default: all four.

.PARAMETER ExcludeWorkload
    One or more of: Exchange, OneDrive, SharePoint, Teams to skip, even if included in
    -Workload (e.g. -ExcludeWorkload Teams to run everything except Teams). Default:
    none excluded.

.PARAMETER SampleSize
    Number of distinct random items to test per workload per organization (fewer are
    sampled if that many don't exist). All samples come from the single restore point
    session opened for that workload/organization - no extra sessions are opened.
    Default: 1.

.PARAMETER ArchiverDllPath
    Path to Veeam.Archiver.PowerShell.dll. Importing by DLL path (instead of by module
    name) avoids the pwsh 7 Windows PowerShell compatibility/implicit-remoting layer,
    which is known to silently drop -Confirm:$false on some VB365 cmdlets.

.EXAMPLE
    ./vb365-RandomItemRestore.ps1 -ExportPath D:\RecoverabilityTest
    # Runs against localhost using the current Windows session, no -Credential needed.

.EXAMPLE
    ./vb365-RandomItemRestore.ps1 -Server vbo365.contoso.local -Credential $cred `
        -OrganizationName "Contoso*" -Workload Exchange,OneDrive -SampleSize 3 -ExportPath D:\RecoverabilityTest
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Server = 'localhost',

    [int]$Port = 9191,

    [PSCredential]$Credential,

    [string]$OrganizationName = '*',

    [Parameter(Mandatory)]
    [string]$ExportPath,

    [ValidateSet('Exchange', 'OneDrive', 'SharePoint', 'Teams')]
    [string[]]$Workload = @('Exchange', 'OneDrive', 'SharePoint', 'Teams'),

    [ValidateSet('Exchange', 'OneDrive', 'SharePoint', 'Teams')]
    [string[]]$ExcludeWorkload = @(),

    [int]$SampleSize = 1,

    [string]$ArchiverDllPath = 'C:\Program Files\Veeam\Backup365\Veeam.Archiver.PowerShell.dll'
)

$ErrorActionPreference = 'Stop'
$Workload = @($Workload | Where-Object { $ExcludeWorkload -notcontains $_ })
if (-not $Workload) { throw 'All workloads were excluded - nothing to do.' }

$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {
    param($Workload, $Organization, $Target, $Item, $Destination, $Status, $Detail)

    $results.Add([pscustomobject]@{
            Timestamp    = Get-Date
            Workload     = $Workload
            Organization = $Organization
            Target       = $Target
            Item         = $Item
            Destination  = $Destination
            Status       = $Status
            Detail       = $Detail
        })
}

# Draws up to SampleSize distinct items, spread round-robin across distinct targets
# (mailbox/user/site/team): a target already used in the current round is skipped in
# favor of one that hasn't contributed yet, so multiple samples don't pile up on a
# single target just because it happens to have plenty of items. A target is only
# reused once every currently-known target has contributed at least one sample, and a
# brand-new candidate is only queried when no already-known target has items left to
# offer this round.
function Get-NextSample {
    param(
        [System.Collections.Generic.Queue[object]]$Queue,
        [System.Collections.Generic.List[object]]$Buckets,
        [System.Collections.Generic.HashSet[object]]$UsedTargetsThisRound,
        [scriptblock]$FetchItems
    )

    while ($true) {
        $eligible = @($Buckets | Where-Object { $_.Items.Count -gt 0 -and -not $UsedTargetsThisRound.Contains($_.Target) })
        if ($eligible) {
            $bucket = $eligible | Get-Random
            $item = $bucket.Items | Get-Random
            $bucket.Items.Remove($item) | Out-Null
            $UsedTargetsThisRound.Add($bucket.Target) | Out-Null
            return [pscustomobject]@{ Target = $bucket.Target; Item = $item }
        }

        if ($Queue.Count -gt 0) {
            $candidate = $Queue.Dequeue()
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($i in (& $FetchItems $candidate)) { $items.Add($i) }
            if ($items.Count -gt 0) { $Buckets.Add([pscustomobject]@{ Target = $candidate; Items = $items }) }
            continue
        }

        if (@($Buckets | Where-Object { $_.Items.Count -gt 0 })) {
            $UsedTargetsThisRound.Clear()
            continue
        }

        return $null
    }
}

function Test-ExchangeRandomRestore {
    param($Organization)

    $session = $null
    try {
        $session = Start-VBOExchangeItemRestoreSession -Organization $Organization -LatestState
        $mailboxes = Get-VEXDatabase -Session $session | ForEach-Object { Get-VEXMailbox -Database $_ }
        if (-not $mailboxes) { throw 'No mailboxes found in latest restore point.' }

        $queue = [System.Collections.Generic.Queue[object]]::new([object[]]($mailboxes | Get-Random -Count $mailboxes.Count))
        $buckets = [System.Collections.Generic.List[object]]::new()
        $usedTargetsThisRound = [System.Collections.Generic.HashSet[object]]::new()

        1..$SampleSize | ForEach-Object {
            $sampleIndex = $_
            try {
                $picked = Get-NextSample -Queue $queue -Buckets $buckets -UsedTargetsThisRound $usedTargetsThisRound -FetchItems {
                    param($mailbox)
                    @(Get-VEXItem -Mailbox $mailbox)
                }
                if (-not $picked) { throw 'No more distinct Exchange items available in this organization.' }
                $mailbox = $picked.Target
                $item = $picked.Item

                $destFolder = Join-Path $ExportPath "Exchange\$($Organization.Name)"
                New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
                $destFile = Join-Path $destFolder "$($mailbox.Name)-$(Get-Date -Format yyyyMMdd-HHmmss)-$sampleIndex.pst"
                Export-VEXItem -Item $item -To $destFile -Force | Out-Null

                Add-Result 'Exchange' $Organization.Name $mailbox.Name $item.Subject $destFile 'Success' $null
                Write-Host "  [Exchange]   OK   - $($mailbox.Name): '$($item.Subject)' -> $destFile" -ForegroundColor Green
            }
            catch {
                Add-Result 'Exchange' $Organization.Name $null $null $null 'Failed' $_.Exception.Message
                Write-Host "  [Exchange]   FAIL - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    finally {
        if ($session) { Stop-VBOExchangeItemRestoreSession -Session $session }
    }
}

function Test-OneDriveRandomRestore {
    param($Organization)

    $session = $null
    try {
        $session = Start-VEODRestoreSession -Organization $Organization -LatestState
        $users = Get-VEODUser -Session $session
        if (-not $users) { throw 'No OneDrive users found in latest restore point.' }

        $queue = [System.Collections.Generic.Queue[object]]::new([object[]]($users | Get-Random -Count $users.Count))
        $buckets = [System.Collections.Generic.List[object]]::new()
        $usedTargetsThisRound = [System.Collections.Generic.HashSet[object]]::new()

        1..$SampleSize | ForEach-Object {
            try {
                $picked = Get-NextSample -Queue $queue -Buckets $buckets -UsedTargetsThisRound $usedTargetsThisRound -FetchItems {
                    param($user)
                    @(Get-VEODDocument -User $user -Recurse |
                        Where-Object { -not ($_.PSObject.Properties['IsFolder'] -and $_.IsFolder) })
                }
                if (-not $picked) { throw 'No more distinct OneDrive files available in this organization.' }
                $user = $picked.Target
                $doc = $picked.Item

                $dest = Join-Path $ExportPath "OneDrive\$($Organization.Name)\$($user.Name)"
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Save-VEODDocument -Document $doc -Path $dest

                Add-Result 'OneDrive' $Organization.Name $user.Name $doc.Name $dest 'Success' $null
                Write-Host "  [OneDrive]   OK   - $($user.Name): '$($doc.Name)'" -ForegroundColor Green
            }
            catch {
                Add-Result 'OneDrive' $Organization.Name $null $null $null 'Failed' $_.Exception.Message
                Write-Host "  [OneDrive]   FAIL - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    finally {
        if ($session) { Stop-VEODRestoreSession -Session $session }
    }
}

function Test-SharePointRandomRestore {
    param($Organization)

    $session = $null
    try {
        $session = Start-VBOSharePointItemRestoreSession -Organization $Organization -LatestState
        $vespOrg = Get-VESPOrganization -Session $session
        $sites = Get-VESPSite -Organization $vespOrg -Recurse
        if (-not $sites) { throw 'No SharePoint sites found in latest restore point.' }

        $queue = [System.Collections.Generic.Queue[object]]::new([object[]]($sites | Get-Random -Count $sites.Count))
        $buckets = [System.Collections.Generic.List[object]]::new()
        $usedTargetsThisRound = [System.Collections.Generic.HashSet[object]]::new()

        1..$SampleSize | ForEach-Object {
            try {
                $picked = Get-NextSample -Queue $queue -Buckets $buckets -UsedTargetsThisRound $usedTargetsThisRound -FetchItems {
                    param($site)
                    # VESPDocumentLibrary exposes no Hidden/IsHidden property, so system libraries
                    # (wiki pages, style/site assets, form templates) can't be filtered by a real
                    # flag - exclude the well-known ones by name/URL instead.
                    $libraries = @(Get-VESPDocumentLibrary -Site $site -Recurse | Where-Object {
                            $_.ItemsCount -gt 0 -and
                            $_.Name -notmatch '(?i)^(Site Pages|Style Library|Site Assets|Form Templates|Site Collection Images|Teams Wiki Data|Preservation Hold Library)$' -and
                            $_.Url -notmatch '(?i)/(sitepages|styles|siteassets|formservertemplates|siteCollectionImages)(/|$)'
                        })
                    @(foreach ($lib in $libraries) { Get-VESPDocument -DocumentLibrary $lib -Recurse | Where-Object { -not $_.IsContainer } })
                }
                if (-not $picked) { throw 'No more distinct SharePoint documents available in this organization.' }
                $site = $picked.Target
                $item = $picked.Item

                $dest = Join-Path $ExportPath "SharePoint\$($Organization.Name)\$($site.Url)"
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Save-VESPItem -Document $item -Path $dest -Force

                Add-Result 'SharePoint' $Organization.Name $site.Url $item.Name $dest 'Success' $null
                Write-Host "  [SharePoint] OK   - $($site.Url): '$($item.Name)'" -ForegroundColor Green
            }
            catch {
                Add-Result 'SharePoint' $Organization.Name $null $null $null 'Failed' $_.Exception.Message
                Write-Host "  [SharePoint] FAIL - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    finally {
        if ($session) { Stop-VBOSharePointItemRestoreSession -Session $session }
    }
}

function Test-TeamsRandomRestore {
    param($Organization)

    $session = $null
    try {
        $session = Start-VBOTeamsItemRestoreSession -Organization $Organization -LatestState
        $vetOrg = Get-VETOrganization -Session $session
        $teams = Get-VETTeam -Organization $vetOrg
        if (-not $teams) { throw 'No Teams found in latest restore point.' }

        $queue = [System.Collections.Generic.Queue[object]]::new([object[]]($teams | Get-Random -Count $teams.Count))
        $buckets = [System.Collections.Generic.List[object]]::new()
        $usedTargetsThisRound = [System.Collections.Generic.HashSet[object]]::new()

        1..$SampleSize | ForEach-Object {
            try {
                $picked = Get-NextSample -Queue $queue -Buckets $buckets -UsedTargetsThisRound $usedTargetsThisRound -FetchItems {
                    param($team)
                    @(Get-VETPost -Team $team) + @(Get-VETFile -Team $team)
                }
                if (-not $picked) { throw 'No more distinct Teams posts or files available in this organization.' }
                $team = $picked.Target
                $item = $picked.Item
                $isPost = $item.GetType().Name -eq 'VETPost'

                $dest = Join-Path $ExportPath "Teams\$($Organization.Name)\$($team.DisplayName)"
                New-Item -ItemType Directory -Path $dest -Force | Out-Null

                if ($isPost) {
                    Save-VETItem -Post $item -Path $dest -Force
                    $itemName = "Post: $($item.Id)"
                }
                else {
                    Save-VETItem -File $item -Path $dest -Force
                    $itemName = $item.Name
                }

                Add-Result 'Teams' $Organization.Name $team.DisplayName $itemName $dest 'Success' $null
                Write-Host "  [Teams]      OK   - $($team.DisplayName): '$itemName'" -ForegroundColor Green
            }
            catch {
                Add-Result 'Teams' $Organization.Name $null $null $null 'Failed' $_.Exception.Message
                Write-Host "  [Teams]      FAIL - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    finally {
        if ($session) { Stop-VBOTeamsItemRestoreSession -Session $session }
    }
}

# --- Import module by DLL path: pwsh 7 loading it by name routes through the
#     Windows PowerShell compatibility layer, which silently drops -Confirm:$false
#     on some VB365 cmdlets. ---
if (Test-Path $ArchiverDllPath) {
    Import-Module $ArchiverDllPath -ErrorAction Stop
}
else {
    Write-Warning "Archiver DLL not found at '$ArchiverDllPath'; falling back to Import-Module by name (some cmdlets may silently ignore -Confirm:`$false under this path)."
    Import-Module Veeam.Archiver.PowerShell -ErrorAction Stop
}

# Nest every run's output under its own timestamped subfolder so repeated runs don't
# overwrite or mix with each other's exports/report.
$ExportPath = Join-Path $ExportPath (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null

# Disconnect any pre-existing session first; Connect-VBOServer fails if one is already active.
try { Disconnect-VBOServer -ErrorAction SilentlyContinue } catch {}

if ($Credential) {
    Connect-VBOServer -Server $Server -Port $Port -Credential $Credential
}
else {
    Connect-VBOServer -Server $Server -Port $Port
}

try {
    $orgs = Get-VBOOrganization -Name $OrganizationName
    if (-not $orgs) { throw "No organization found matching '$OrganizationName'." }

    foreach ($org in $orgs) {
        Write-Host "=== Organization: $($org.Name) ===" -ForegroundColor Cyan

        foreach ($rp in @(Get-VBORestorePoint -Organization $org -Latest)) {
            $coveredWorkloads = @(
                if ($rp.IsExchange) { 'Exchange' }
                if ($rp.IsSharePoint) { 'SharePoint' }
                if ($rp.IsOneDrive) { 'OneDrive' }
                if ($rp.IsTeams) { 'Teams' }
            ) -join ', '
            $rpDetail = "BackupTime=$($rp.BackupTime) JobId=$($rp.JobId) RepositoryId=$($rp.RepositoryId) Workloads=$coveredWorkloads"
            Add-Result 'RestorePoint' $org.Name $null $null $null 'Info' $rpDetail
            Write-Host "  Restore point used: $rpDetail" -ForegroundColor DarkCyan
        }

        if ($Workload -contains 'Exchange') { Test-ExchangeRandomRestore -Organization $org }
        if ($Workload -contains 'OneDrive') { Test-OneDriveRandomRestore -Organization $org }
        if ($Workload -contains 'SharePoint') { Test-SharePointRandomRestore -Organization $org }
        if ($Workload -contains 'Teams') { Test-TeamsRandomRestore -Organization $org }
    }
}
finally {
    Disconnect-VBOServer
}

$results | Format-Table -AutoSize

$reportPath = Join-Path $ExportPath "RandomItemRestore-Report-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv -Path $reportPath -NoTypeInformation
Write-Host "Report saved to $reportPath"

$failures = $results | Where-Object Status -eq 'Failed'
if ($failures) {
    Write-Warning "$($failures.Count) of $($results.Count) sampled item(s) failed the recoverability test."
    exit 1
}

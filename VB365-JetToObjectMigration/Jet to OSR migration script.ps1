# Copyright © Veeam Software Group GmbH

# Variables - set these accordingly
$reportPath = "C:\VBOMigrationReports"

# If VBO is installed in a different path, please replace it with your own path.
Import-Module 'C:\Program Files\Veeam\Backup365\Veeam.Archiver.PowerShell.dll'


# Logging Function
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "SUCCESS", "WARNING")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Color mapping for different log levels
    $colors = @{
        "INFO"    = "White"
        "SUCCESS" = "Green"
        "WARNING" = "Yellow"
    }
    
    $color = $colors[$Level]
    
    if ($NoNewLine) {
        Write-Host $logMessage -ForegroundColor $color -NoNewline
    } else {
        Write-Host $logMessage -ForegroundColor $color
    }
}

# Helper functions for different log levels
function Write-LogInfo($Message) { Write-Log -Message $Message -Level "INFO" }
function Write-LogSuccess($Message) { Write-Log -Message $Message -Level "SUCCESS" }
function Write-LogWarning($Message) { Write-Log -Message $Message -Level "WARNING" }

# Function to format comparison differences
function Format-ComparisonDifferences {
    param(
        [Parameter(Mandatory=$true)]
        [object]$DiffObject,
        
        [Parameter(Mandatory=$true)]
        [string]$DataType
    )
    
    Write-LogWarning "$DataType data mismatch detected! Differences:"
    $DiffObject | Select-Object @{Name="Repository";Expression={
             switch ($_.SideIndicator) {
                 "=>" { "Target" }
                 "<=" { "Source" }
             }
         }}, * | Select-Object -ExcludeProperty SideIndicator | Format-Table -AutoSize
}

# Function to compare data between source and target inventories
function Compare-InventoryData {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$SourceInventoryReport,
        
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$TargetInventoryReport,
        
        [Parameter(Mandatory=$true)]
        [string]$DataType,
        
        [Parameter(Mandatory=$true)]
        [string[]]$CompareProperties
    )
    
    $SourceInventoryReportIsMissing = [string]::IsNullOrEmpty($SourceInventoryReport)
    $TargetInventoryReportIsMissing = [string]::IsNullOrEmpty($TargetInventoryReport)
    
    if (-not $SourceInventoryReportIsMissing -and -not $TargetInventoryReportIsMissing) {
        Write-LogInfo "Comparing $DataType..."
        $sourceCsv = Import-Csv -Path $SourceInventoryReport
        $targetCsv = Import-Csv -Path $TargetInventoryReport
        $diff = Compare-Object -ReferenceObject $sourceCsv -DifferenceObject $targetCsv -Property $CompareProperties
        return $diff
    } else {
        $missingReports = @()
        if ($SourceInventoryReportIsMissing) { $missingReports += "Source" }
        if ($TargetInventoryReportIsMissing) { $missingReports += "Target" }        
        $missingText = $missingReports -join " and "

        if ((-not $SourceInventoryReportIsMissing -and $TargetInventoryReportIsMissing) -or ($SourceInventoryReportIsMissing -and -not $TargetInventoryReportIsMissing)) {
            if (-not $SourceInventoryReportIsMissing) { $presentReport = "Source" }
            if (-not $TargetInventoryReportIsMissing) { $presentReport = "Target" } 

            Write-LogWarning "$DataType report found only in $presentReport inventory, but is missing in $missingText inventory. Skipping $DataType comparison. This may happen e.g. when you were migrating data for specific Job, but verifying data for whole Organization."
        } else {
            Write-LogInfo "No $DataType report found in $missingText inventory. Skipping $DataType comparison."
        }
        return $null
    }
}
# ---------------------------------------------------------------------------------------

# Organization selection
Write-Host "Select Organization:"
$orgs = Get-VBOOrganization | Sort-Object Name
for($i=0; $i -lt $orgs.count; $i++) { Write-Host $i. $orgs[$i].name }
$organisationNum = Read-Host "Enter organization number"
$organization = $orgs[$organisationNum]
Write-Host

# Validation type selection
Write-Host "Select validation type:"
Write-Host "0. Organization"
Write-Host "1. Job"
$validationTypeNum = Read-Host "Enter validation type number"
Write-Host

if ($validationTypeNum -eq "1") {
    # Job selection
    Write-Host "Select Job:"
    $jobs = Get-VBOJob -Organization $organization | Sort-Object Name
    for($i=0; $i -lt $jobs.count; $i++) { Write-Host $i. $jobs[$i].name }
    $jobNum = Read-Host "Enter job number"
    $selectedJob = $jobs[$jobNum]
    $validationTarget = $selectedJob
    $validationType = "Job"
    $inventoryDataIdColumnName = "Backup Job Id"
    Write-Host
} else {
    $validationTarget = $organization
    $validationType = "Organization"
    $inventoryDataIdColumnName = "Organization Id"    
}

# Source Repository selection
Write-Host "Select Source Repository:"
$sourceRepos = Get-VBORepository | Where-Object{($_.ObjectStorageRepository -eq $Null) -and (Get-VBOEntityData -Repository $_ -Type Organization -Name $organization.Name) -ne $Null} | Sort-Object Name
for($i=0; $i -lt $sourceRepos.count; $i++) { Write-Host $i.  $sourceRepos[$i].name }
$sourceRepoNum = Read-Host  "Enter Source repository number"
$sourceRepository = $sourceRepos[$sourceRepoNum]
Write-Host

# Target Repository selection
Write-Host "Select Target Repository:"
$targetRepos = Get-VBORepository | Where-Object{($_.ObjectStorageRepository -ne $Null) -and (Get-VBOEntityData -Repository $_ -Type Organization -Name $organization.Name) -ne $Null} | Sort-Object Name
for($i=0; $i -lt $targetRepos.count; $i++) { Write-Host $i.  $targetRepos[$i].name }
$targetRepoNum = Read-Host  "Enter Target repository number"
$targetRepository = $targetRepos[$targetRepoNum]
Write-Host

# Verify Data Migration (compare inventory reports)
$latestRestorePoint = Get-VBORestorePoint -Repository $sourceRepository -Latest

Write-LogInfo "Generating inventory reports for source repository..."
if ($validationType -eq "Organization") {
    $sourceInventory = Get-VBORepositoryInventoryReport -OutputPath $reportPath -BackupTime $latestRestorePoint.BackupTime -Repository $sourceRepository -Organization $organization -IncludeAllVersions -IncludeDeleted
} else {
    $sourceInventory = Get-VBORepositoryInventoryReport -OutputPath $reportPath -BackupTime $latestRestorePoint.BackupTime -Repository $sourceRepository -Job $selectedJob -IncludeAllVersions -IncludeDeleted
}

Write-LogInfo "Generating inventory reports for target repository..."
if ($validationType -eq "Organization") {
    $targetInventory = Get-VBORepositoryInventoryReport -OutputPath $reportPath -BackupTime $latestRestorePoint.BackupTime -Repository $targetRepository -Organization $organization -IncludeAllVersions -IncludeDeleted
} else {
    $targetInventory = Get-VBORepositoryInventoryReport -OutputPath $reportPath -BackupTime $latestRestorePoint.BackupTime -Repository $targetRepository -Job $selectedJob -IncludeAllVersions -IncludeDeleted
}
Write-Host

# Compare Mailboxes
$mailDiff = Compare-InventoryData -SourceInventoryReport ($sourceInventory ? $sourceInventory.MailboxesReport : $null) -TargetInventoryReport ($targetInventory ? $targetInventory.MailboxesReport : $null) -DataType "Mailboxes" -CompareProperties @($inventoryDataIdColumnName, "Mailbox ID", "Mailbox Name", "Mailbox Folder Count", "Mailbox Item Count")

# Compare SharePoint Sites
$websDiff = Compare-InventoryData -SourceInventoryReport ($sourceInventory ? $sourceInventory.RootWebsReport : $null) -TargetInventoryReport ($targetInventory ? $targetInventory.RootWebsReport : $null) -DataType "SharePoint Sites" -CompareProperties @($inventoryDataIdColumnName, "Site ID", "Root Site ID", "Root Site URL", "Root Site Hierarchy Item Version Count")

# Compare Teams
$teamsDiff = Compare-InventoryData -SourceInventoryReport ($sourceInventory ? $sourceInventory.TeamsReport : $null) -TargetInventoryReport ($targetInventory ? $targetInventory.TeamsReport : $null) -DataType "Teams" -CompareProperties @($inventoryDataIdColumnName, "Team ID", "Team Name", "Team Channel Message Count", "Team Tab Count", "Team Channel Count", "Team File Count", "Team User Count")

# Compare OneDrive
$oneDrivesDiff = Compare-InventoryData -SourceInventoryReport ($sourceInventory ? $sourceInventory.OneDrivesReport : $null) -TargetInventoryReport ($targetInventory ? $targetInventory.OneDrivesReport : $null) -DataType "OneDrive" -CompareProperties @($inventoryDataIdColumnName, "Account Name", "OneDrive Item Count")

# Print all differences, if any
Write-Host
$hasDiff = $false

if ($mailDiff) {
    Format-ComparisonDifferences -DiffObject $mailDiff -DataType "Mailboxes"
    $hasDiff = $true
}

if ($websDiff) {
    Format-ComparisonDifferences -DiffObject $websDiff -DataType "SharePoint"
    $hasDiff = $true
}

if ($teamsDiff) {
    Format-ComparisonDifferences -DiffObject $teamsDiff -DataType "Teams"
    $hasDiff = $true
}

if ($oneDrivesDiff) {
    Format-ComparisonDifferences -DiffObject $oneDrivesDiff -DataType "OneDrive"
    $hasDiff = $true
}

if ($hasDiff) {
    throw "Data verification failed! See above for details on mismatches."
}

Write-LogSuccess "Data verification completed successfully. No differences found."
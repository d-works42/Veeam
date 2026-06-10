# Veeam Backup for Microsoft 365 - Jet to Object Storage Migration
This project has the goal to support in migrating backup data from disk Repositories to object storage Repositories.

## Important note:
Please be aware that the provided information and code is only seen as examples and are not officially tested and supported by Veeam. The used commands themself are supported, since they are offered directly through the product.

## Good to know
- **Veeam Backup for Microsoft 365** will be called **VB365** as an acronym in this document.
- This migration option is only supported from Jet to Object Storage.
- Disk repositories are always bound to a single windows based Proxy.
- 

## Hints for commands
- Most commands require some objects to run. For example, the Start-VBODataMigration cmdlet requires objects for source and target repositories as well as the proxy. These objects can be created with Get-VBORepository and Get-VBOProxy.
- 

## Workflow overview

1. Disable retention on the source proxy
2. Enable Data Migration feature
3. Start migration to an empty target repository
4. Monitor status until you see Success or Warning
5. Manage migrations
6. Verify data consistency by comparing source and target repository inventory reports
7. Remove migration lock to enable regular use of the target repository
8. (optional) Enable retention on the source proxy

## Workflow steps in detail
### 1. Disable retention on the source proxy

#### Purpose
Prevents the retention cleanup job from deleting recently migrated data, which can cause verification errors.
#### Outcome
Disables retention for the source repository, ensuring all data remains on the source during migration.
#### Execute
```
Set-VBOConfigurationParameter -XPath "/Veeam/Archiver/RepositoryConfig" -Key
"RetentionDisabled" -Value "True" -Proxy {proxy}
```
#### Notes
The {proxy} parameter is a VB365 Proxy object which needs to be created with the Get-VBOProxy cmdlet. 
Example:
```
$proxy = Get-VBOProxy -Hostname proxy01

Set-VBOConfigurationParameter -XPath "/Veeam/Archiver/RepositoryConfig" -Key
"RetentionDisabled" -Value "True" -Proxy $proxy
```
### 2. Enable Data Migration feature
#### Purpose
Some Data Migration related cmdlets are disabled by default and they must be enabled first.
#### Execute
```
[Environment]::SetEnvironmentVariable("VEEAM_DATA_MIGRATION_ENABLED", "true")
```
#### Notes
Setting this in a PowerShell session is only kept for the current session. If needed frequently please add this variable globally in the system.

### 3. Start migration to an empty target repository
#### Purpose
Begins the migration of data from a source repository to a target repository
#### Prerequisites 
The target repository must be empty. Starting a migration creates a migration lock on the target repository, restricting its use to ongoing migration only.
#### Execute
An example script to ease the start of a jod mode migration by selection can be found in this folder: *VB365-JetToOsrMigration.ps1*

The manual start of a migration can be done in the following ways:

Job mode:
```
Start-VBODataMigration -Job <VBOJob> -To <VBORepository> [-SwitchJobToTargetRepository] [-RunAsync]
```
Organization mode:
```
Start-VBODataMigration -Organization <VBOOrganization> -From <VBORepository> -To <VBORepository> [-SwitchJobToTargetRepository] [-RunAsync]
```
#### Outcome
Returns a migration session ID (JobId) for tracking progress if run with *-RunAsync*
#### Notes
If you use the *-SwitchJobToTargetRepository* parameter, the job switches only after a successful migration. If themigration finishes with errors or warnings, the switch does not occur. After switching, the job remains disabled until you perform the migration verification check and remove migration lock.

### 4. Monitor status
#### Purpose
Tracks the status of the migration session using the session ID.
Key status values:
- Success: Migration completed successfully.
- Warning: Migration completed with non critical warnings.
- Failed: Migration failed.
- Running, Stopped, etc.: Indicates current progress/state.
#### Execute
To get the status of all migration jobs:
```
Get-VBODataMigration
```
To get the status of a specific migration job:
```
Get-VBODataMigration Get-VBODataMigration -id <JobID>
```

### 5. Manage migration jobs
In case it is needed to suspend or stop a migration job, the commands 
*Suspend-VBODataMigration* , *Resume-VBODataMigration* and *Stop-vBODataMigration* can be used.
#### Execute
Get the object for the migration to manage:
```
$migration = Get-VBODataMigration -id <JobID>
```
Suspend a migration:
```
Suspend-VBODataMigration -migration $migration
```
Resume a migration:
```
Resume-VBODataMigration -migration $migration [-RunAsync]
```
Stop a migration and end the process:
```
Stop-VBODataMigration -migration $migration
```
#### Notes
When a migration is stopped, no switch of the backup job or unlocking is taking place.
Managing migration jobs with these commands might take a moment to complete.

### 5. Verify Data Consistency
#### Purpose
Export inventory reports from both the source and target repositories for comparison, in order to verify that all items were successfully migrated. The Verification PowerShell Script *VB365_JetToOsrVerification.ps1* in this folder can be used to compare the data.
#### Outcome 
No differences should be found between source and target. If any differences are detected, it could indicate a data loss during the migration process. In such case, try to run the migration again and if the issue persists, open a support ticket.
#### Execute
Adjust the Verification PowerShell Script *VB365_JetToOsrVerification.ps1* log path in $reportPath if needed. Run the script and follow the selections.
#### Notes
The provided script in this folder is provided to ease the process for data verification.

### 6. Remove Migration Lock 
#### Purpose
Removes the migration lock from the target repository, allowing normal operations such as backups and retention jobs.
#### Execute
```
Remove-VBODataMigrationLock 
```
#### Note
Once the lock is removed, you cannot repeat the migration for the same data set.
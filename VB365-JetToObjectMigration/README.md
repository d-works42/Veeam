# Veeam Backup for Microsoft 365 - Jet to Object Storage Migration
This project has the goal to support in migrating backup data from disk Repositories to object storage Repositories.

## Important note:
Please be aware that the provided information and code is only seen as examples and are not officially tested and supported by Veeam. The used commands themself are supported, since they are offered directly through the product.

## Good to know
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
5. Verify data consistency by comparing source and target repository inventory reports
6. Remove migration lock to enable regular use of the target repository
7. (optional) Enable retention on the source proxy

## Workflow steps in detail
### Disable retention on the source proxy

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
The {proxy} needs to be a proxy object which needs to be created with the Get-VBOProxy cmdlet. Example:
```
$proxy = Get-VBOProxy -Hostname proxy01

Set-VBOConfigurationParameter -XPath "/Veeam/Archiver/RepositoryConfig" -Key
"RetentionDisabled" -Value "True" -Proxy $proxy
```

# Veeam Backup for Microsoft 365 - Jet to Object Storage Migration
This project has the goal to support in migrating backup data from disk Repositories to object storage Repositories.

## Important note:
Please be aware that the provided information and code is only seen as examples and are not officially tested and supported by Veeam. The used commands themself are supported, since they are offered directly through the product.

## Good to know
- This migration option is only supported from Jet to Object Storage.
- Disk repositories are always bound to a single windows based Proxy.
- Source and Target Repository need to be bound to the same Proxy during the migration process.

## Hints for commands
- Most commands require some objects to run. For example, the Start-VBODataMigration cmdlet requires objects for source and target repositories as well as the proxy. These objects can be created with Get-VBORepository and Get-VBOProxy.
- 
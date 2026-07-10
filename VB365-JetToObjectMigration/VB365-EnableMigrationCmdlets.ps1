# If VBO is installed in a different path, please replace it with your own path.
Import-Module 'C:\Program Files\Veeam\Backup365\Veeam.Archiver.PowerShell.dll'

#enable the migration option (on VB365 server)
[Environment]::SetEnvironmentVariable("VEEAM_DATA_MIGRATION_ENABLED", "true")
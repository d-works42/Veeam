Unity-snapshot-orchestration
This script creates a snapshot in a DellEMC Unity system for the path of a defined SMB share. The snapshot is presented as a new share for backup purpose.

Hugh kodos go to Erwan Quélin who created the PowerShell Module for Unity which is used by this script: https://github.com/equelin/Unity-Powershell

Based on https://github.com/marcohorstmann/psscripts/tree/master/NASBackup by Marco Horstmann (marco.horstmann@veeam.com)

This is version 1.2

Example
.\Invoke-UnityNASBackup.ps1 -Script:UnityName unity01 -Script:UnityShare share01 -Script:UnityCredentialFile C:\Scripts\unit-credentials.xml -Script:SnapshotName VeeamNASBackup

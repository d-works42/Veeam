<#
.SYNOPSIS
    Finds object storage repositories that are safe migration targets for a given organization.

.DESCRIPTION
    For the organization passed in, returns every object storage backup repository in the
    Veeam Backup for Microsoft 365 infrastructure that is EITHER:
        * not assigned to any backup job, OR
        * holds no backed-up data belonging to a different organization
          (i.e. it is empty, or only contains data for the given organization).

    Output is an array of VBORepository objects exactly as returned by Get-VBORepository.

    Cmdlet reference (v8):
    https://helpcenter.veeam.com/docs/vbo365/powershell/veeam_psreference.html?ver=8

.PARAMETER OrganizationName
    The name of the organization, e.g. "contoso.onmicrosoft.com". The matching
    VBOOrganization object is retrieved internally via Get-VBOOrganization.

.EXAMPLE
    .\OSRget.ps1 -OrganizationName "contoso.onmicrosoft.com"

.EXAMPLE
    "contoso.onmicrosoft.com" | .\OSRget.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]$OrganizationName
)

begin {
    # Repository targeted by every backup job, collected once so the Where-Object
    # filter below can test "assigned to a job?" without re-querying per repository.
    # NOTE: Get-VBOJob covers primary backup jobs only. Add Get-VBOCopyJob ids here
    #       if backup copy jobs should also count as "assigned".
    $assignedRepositoryIds = @(
        Get-VBOJob |
            Where-Object { $null -ne $_.Repository } |
            ForEach-Object { $_.Repository.Id }
    )
}

process {
    # Resolve the organization name to a VBOOrganization object.
    $Organization = Get-VBOOrganization -Name $OrganizationName
    if ($null -eq $Organization) {
        Write-Error ("No organization found with name '{0}'." -f $OrganizationName)
        return
    }

    # Single filtered pipeline -> emits VBORepository objects.
    Get-VBORepository | Where-Object {
        $_.IsObjectStorage -and (
            # not assigned to a job ...
            ($assignedRepositoryIds -notcontains $_.Id) -or
            # ... OR no data from a different organization: the full set of orgs
            # with data here is not larger than the subset belonging to $Organization.
            (@(Get-VBOEntityData -Repository $_ -Type Organization).Count -le
             @(Get-VBOEntityData -Repository $_ -Organization $Organization).Count)
        )
    }
}

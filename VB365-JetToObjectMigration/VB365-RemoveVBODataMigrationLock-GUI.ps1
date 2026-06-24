<#
.SYNOPSIS
    GUI wrapper to remove the data migration lock from a Veeam Backup for
    Microsoft 365 repository.

.DESCRIPTION
    Presents a window to select a VBO repository, runs Remove-VBODataMigrationLock
    against it, and then shows the resulting MigrationLock state of the repository.

.NOTES
    Requires the Veeam.Archiver.PowerShell module (Veeam Backup for Microsoft 365).
    Run this script in a PowerShell session on the VB365 server.

    NAME:  Remove-VBODataMigrationLock-GUI.ps1
	VERSION: 0.2
	AUTHOR: David Bewernick
	GITHUB: https://github.com/d-works
#>

# --- Ensure STA so Windows Forms dialogs can display ------------------------
if (([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) -and $PSCommandPath) {
    Write-Host "Relaunching in STA mode so Windows Forms dialogs display correctly..."
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Load the Veeam module --------------------------------------------------
# Import the binary module directly by DLL path so it loads natively in-process.
# This avoids the Windows PowerShell compatibility/remoting layer (used when a
# 5.1 module is imported under pwsh 7), which can stop -Confirm:$false from
# suppressing the cmdlet's prompt. Falls back to the module name if not found.
try {
    $veeamDll = 'C:\Program Files\Veeam\Backup365\Veeam.Archiver.PowerShell.dll'
    if (Test-Path -LiteralPath $veeamDll) {
        Import-Module $veeamDll -ErrorAction Stop
    }
    else {
        Import-Module Veeam.Archiver.PowerShell -ErrorAction Stop
    }
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Unable to load the Veeam Backup for Microsoft 365 PowerShell module.`n`n$($_.Exception.Message)",
        "Module Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    return
}

# --- Retrieve the repositories ----------------------------------------------
try {
    # Only list repositories that currently have a migration lock set, since
    # those are the only ones from which a lock can be removed.
    $repositories = Get-VBORepository -ErrorAction Stop |
        Where-Object { $null -ne $_.MigrationLock } |
        Sort-Object Name
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Unable to retrieve repositories.`n`n$($_.Exception.Message)",
        "Repository Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    return
}

if (-not $repositories) {
    [System.Windows.Forms.MessageBox]::Show(
        "No repositories were found.",
        "No Repositories",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    return
}

# --- Build the form ---------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text          = "Remove VBO Data Migration Lock"
$form.Size          = New-Object System.Drawing.Size(520, 360)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox   = $false
$form.MinimizeBox   = $false

# Label for the repository selector
$lblRepo = New-Object System.Windows.Forms.Label
$lblRepo.Text     = "Select repository with migration lock:"
$lblRepo.Location = New-Object System.Drawing.Point(15, 20)
$lblRepo.AutoSize = $true
$form.Controls.Add($lblRepo)

# ComboBox with the repositories
$cmbRepo = New-Object System.Windows.Forms.ComboBox
$cmbRepo.Location      = New-Object System.Drawing.Point(15, 45)
$cmbRepo.Size          = New-Object System.Drawing.Size(475, 24)
$cmbRepo.DropDownStyle = "DropDownList"
foreach ($repo in $repositories) {
    [void]$cmbRepo.Items.Add($repo.Name)
}
$cmbRepo.SelectedIndex = 0
$form.Controls.Add($cmbRepo)

# Button to start removing the lock
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text     = "Remove Migration Lock"
$btnRun.Location = New-Object System.Drawing.Point(15, 80)
$btnRun.Size     = New-Object System.Drawing.Size(180, 30)
$form.Controls.Add($btnRun)

# Output text box
$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location   = New-Object System.Drawing.Point(15, 125)
$txtOutput.Size       = New-Object System.Drawing.Size(475, 150)
$txtOutput.Multiline  = $true
$txtOutput.ReadOnly   = $true
$txtOutput.ScrollBars = "Vertical"
$txtOutput.Font       = New-Object System.Drawing.Font("Consolas", 9)
$txtOutput.Text       = "Attention: If you remove the migration lock, you will be unable to start any other data migration jobs for this repository."
$form.Controls.Add($txtOutput)

# Quit button (closes the window)
$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text         = "Quit"
$btnOk.Location     = New-Object System.Drawing.Point(415, 285)
$btnOk.Size         = New-Object System.Drawing.Size(75, 30)
$btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($btnOk)
$form.AcceptButton = $btnOk

# --- Button click logic -----------------------------------------------------
$btnRun.Add_Click({
  try {
    $selectedName = $cmbRepo.SelectedItem
    $repository   = $repositories | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1

    if (-not $repository) {
        $txtOutput.Text = "Could not resolve the selected repository."
        return
    }

    $btnRun.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $txtOutput.Text = "Removing data migration lock from '$($repository.Name)'..."
    $form.Refresh()

    try {
        # Always suppress the cmdlet's console prompt so it runs without interaction.
        # -Confirm:$false / $ConfirmPreference handle a ShouldProcess prompt; if the
        # cmdlet instead uses ShouldContinue (which ignores both), -Force is required.
        # Add -Force only if the cmdlet actually exposes it, to stay compatible.
        $ConfirmPreference = 'None'
        $params = @{
            Repository  = $repository
            Confirm     = $false
            ErrorAction = 'Stop'
        }
        if ((Get-Command Remove-VBODataMigrationLock).Parameters.ContainsKey('Force')) {
            $params['Force'] = $true
        }
        Remove-VBODataMigrationLock @params

        # Re-query the repository to show the resulting MigrationLock state
        $result = Get-VBORepository -Id $repository.Id | Select-Object Name, MigrationLock
        $txtOutput.Text = ($result | Format-List | Out-String).Trim()
    }
    catch {
        $txtOutput.Text = "An error occurred:`r`n$($_.Exception.Message)"
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnRun.Enabled = $true
    }
  }
  catch {
    # Surface any error in the handler (e.g. an STA/dialog failure) instead of
    # letting it be swallowed silently by the Windows Forms event loop.
    $txtOutput.Text = "Handler error:`r`n$($_.Exception.Message)"
  }
})

# --- Show the form ----------------------------------------------------------
[void]$form.ShowDialog()
$form.Dispose()

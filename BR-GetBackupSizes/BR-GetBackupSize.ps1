<# 
.NAME
     
.SYNOPSIS
    Script to 
.DESCRIPTION
    This script reads the 
	
	ATTENTION: 
	
	To be used under the MIT license.
.LINK
    https://github.com/wcbuerste
#>

param(
 [string]$JobName=$null,
 [string]$JobType="Backup",
 $date=(get-date)
)


# enable (1) or disable (0) logging
$LogEnable = 0

# set the logfile path
$LogFile = "C:\scripts\logs\BR-GetBackupSize.log"

function Write-Log($Info, $Status){
	if ($LogEnable -eq 1){
		$timestamp = get-date -Format "yyyy-mm-dd HH:mm:ss"
		switch($Status){
			Info    {Write-Host "$timestamp $Info" -ForegroundColor Green  ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
			Status  {Write-Host "$timestamp $Info" -ForegroundColor Yellow ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
			Warning {Write-Host "$timestamp $Info" -ForegroundColor Yellow ; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
			Error   {Write-Host "$timestamp $Info" -ForegroundColor Red -BackgroundColor White; "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
			default {Write-Host "$timestamp $Info" -ForegroundColor white "$timestamp $Info" | Out-File -FilePath $LogFile -Append}
		}
	}
}

Write-Log -Info " " -Status Info
Write-Log -Info "-------------- NEW SESSION --------------" -Status Info
Write-Log -Info " " -Status Info

function get-humanreadable {
 param([double]$numc)

 $num = $numc+0

 $trailing= "","K","M","G","T","P","E"
 $i=0

 while($num -gt 1024 -and $i -lt 6) {
  $num= $num/1024
  $i++
 }

 return ("{0:f1} {1}B" -f $num,$trailing[$i])
}

function get-diffstring {
    param([System.TimeSpan]$diff)
    
    if ($diff -ne $null) {
        $days = ""
        if($diff.days -gt 0) {
         $days = ("{0}." -f $diff.Days)
        }

        return ("{3}{0}:{1,2:D2}:{2,2:D2}" -f $diff.Hours,$diff.Minutes,$diff.Seconds,$days);
    } else {
        Write-Error "Null diff"
    }
}

function get-timestring {
    param([System.DateTime]$time,$prev=$null)
    
    if ($time -ne $null) {
        $days = ""

        if(($prev -ne $null) -and ($time -gt $prev)) {
         $diff = ($time - $prev)
         $daysnum = $diff.Days

         $nextdaytest = $time.AddDays(-$daysnum)
         if ($nextdaytest.DayOfYear -ne $prev.DayOfYear) {
            $daysnum += 1
         }

         if ($daysnum -gt 0) {
            $days = (" (+{0}) " -f $daysnum)
         }
        }

        return ("{0,2:D2}:{1,2:D2}:{2,2:D2}{3}" -f $time.Hour,$time.Minute,$time.Second,$days);
    } else {
        Write-Error "Null diff"
    }
}

function translate-status {
     param($text) 
 

     if ($text -ieq "success") {
       return "Success"
     } elseif ($text -ieq "warning" -or $text -ieq "none") {
       return "Warning"
     } elseif ($text -ieq "pending") {
       return "Pending"
     }
     return "Error"
}

function write-sessionrecord {
     param($job,$session)

     $calcs = calculate-job -session $session -job $job
 
     foreach ($vm in $calcs.vms) {
		write-host (-join ($vm.Name,"`t",$calcs.StartDate,"`t",$calcs.Status,"`t",$vm.Transferred))
     }
 }

function calculate-vms {
    param($session)
    $tasks = $session.GetTaskSessions()

    $success = 0;
    $failed = 0;
    $warning = 0;
    $allvms = @()
    $glerr = "ERRSTR";

    foreach($task in $tasks) {
     
         $diff= $task.Progress.Duration;
         #v9.5 u3
         $tstart = $null
         $tstop = $null
        
         if((Get-Member -InputObject $task.Progress -Name "StartTime") -eq $null) {
            $tstart = $task.Progress.StartTimeLocal
            $tstop = $task.Progress.StopTimeLocal
         } else {
            $tstart = $task.Progress.StartTime
            $tstop = $task.Progress.StopTime
         }

         $vm = New-Object -TypeName psobject -Property @{"Name"=$task.Name;
            "Status"=(translate-status -text $text);
            "StartTime"=(get-timestring -time $tstart);
            "EndTime"=(get-timestring -time $tstop -prev $tstart);
            "Size"=(get-humanreadable -num $task.Progress.ProcessedSize);
            "Read"=(get-humanreadable -num $task.Progress.ReadSize);
            "Transferred"=(get-humanreadable -num $task.Progress.TransferedSize);
            "Duration"=(get-diffstring -diff $task.Progress.Duration);
            "Details"=$task.GetDetails()
            }
         #write-host "Total before: $global:totalTransferred"
         #write-host $vm.Transferred
         #$global:totalTransferred += $task.Progress.TransferedSize
         #write-host "Total after: $global:totalTransferred"
		#write-host (-join ($vm.Name,",",$vm.StartTime,",",$vm.Transferred,",",$vm.Status))
        $allvms += $vm
        $glerr += $task.GetDetails()
    }
    return New-Object -TypeName psobject -Property @{vms=$allvms;failed=$failed;success=$success;warning=$warning;glerr=$glerr}
    
}

function calculate-job {
     param($session,$job)  

     $obj = New-Object -TypeName psobject -Property @{Jobname=$session.Name;
        Jobtype=$session.JobType;
        Jobdescription=$job.Description;
        Status=(translate-status -text $session.Result);

        "CreationTime"=$session.CreationTime;
        "EndTime"=$session.EndTime;
		"StartTime"=$session.StartTime;
        "StartDate"=$session.CreationTime.ToShortDateString();
        "LongStartDateTime"=($session.CreationTime.ToLongDateString()+" "+$session.CreationTime.ToLongTimeString())
        "ProcessedObjects"=$session.Progress.ProcessedObjects;
        "TotalObjects"=$session.Progress.TotalObjects;
        "TotalSize"=(get-humanreadable -num $session.Progress.TotalSize);
        "BackupSize"=(get-humanreadable -num $session.BackupStats.BackupSize);
        "LongCreationTime"=(get-timestring -time $session.CreationTime);
        "LongEndTime"=(get-timestring -time $session.EndTime -prev $session.CreationTime);
        "DataRead"=(get-humanreadable -num $session.Progress.ReadSize);
        "Dedupe"=("{0:N1}x" -f $session.BackupStats.GetDedupeX());
        "Duration"=(get-diffstring -diff $session.Progress.Duration);
        "TransferSize"=(get-humanreadable -num $Session.Progress.TransferedSize);
        "Compression"=("{0:N1}x" -f $session.BackupStats.GetCompressX());
        "Details"=$session.GetDetails();        
        }
        #write-host " "
        #write-host "------"
        #write-host " "
        #write-host $session.Name
        #write-host $session.TotalObjects
        #write-host $obj.StartDate


    #bug where GetTaskSessions() modifies TotalSize (doubles the number)
    #still need to report
    #fix by calling the method after
    $calcs = calculate-vms -session $session
    #write-host (-join ($calcs.vms.Name,"`t",$obj.StartDate,"`t",$calcs.vms.Transferred))
    $obj | Add-Member -Name Failed -Value $calcs.failed -MemberType NoteProperty
    $obj | Add-Member -Name Warning -Value $calcs.warning -MemberType NoteProperty
    $obj | Add-Member -Name Success -Value $calcs.success -MemberType NoteProperty
    $obj | Add-Member -Name Vms -Value $calcs.vms -MemberType NoteProperty


    if ($session.Result -eq "None" -and $session.JobType -eq "BackupSync") {
        if($session.State -eq "Idle" -and $calcs.failed -eq 0 -and $calcs.warning -eq 0 -and $calcs.glerr -eq "ERRSTR" -and $obj.Details -eq ""  -and $session.EndTime -gt $session.CreationTime ) {
            if ($session.Progress.Percents -eq 100) {
                $obj.Status=(translate-status -text "Success");
            } 
        } 
    }

    return $obj
}

write-host "Job Name: $JobName"

if ($JobName -ne $null -and $JobName -ne "") {
    $Jobs = @(Get-VBRJob -Name $JobName)
    if ($Jobs.Count -gt 0) {
        $Job = $Jobs[0];
        $jt = $job.JobType;

        if ($jt -eq "Backup" -or $jt -eq "Replica" -or $jt -eq "BackupSync") {
            

            $sessions = Get-VBRBackupSession -Name ("{0}*" -f $Job.Name) | ? { $_.jobname -eq $Job.Name } 
            $orderdedsess = $sessions | Sort-Object -Property CreationTimeUTC -Descending

            foreach($sess in $orderdedsess) {
                write-sessionrecord -job $Job -session $sess
                
            }
            $wrotesessions = $true;

        } else {
          Write-Error "Job can only be backup, backup copy or replication job. Cannot be $jt"  
        }
    } else {
       Write-Error "Can not find Job with name $JobName"
    }
} else {
  if ($jobtype -ieq "Backup" -or $jobtype -ieq "Replica" -or $jobtype -ieq "BackupSync") {
      $Jobs = @(Get-VBRJob | ? { $_.JobType -ieq $jobtype }) | Sort-Object -Property Name
      if ($Jobs.Count -ne 0) {
            $wrotesessions = $true;
            $allsessions = Get-VBRBackupSession | ? { $_.jobtype -ieq $JobType } 
            $allorderdedsess = $allsessions | Sort-Object -Property CreationTimeUTC -Descending  
 
            $rpo = $null
            if ($RPOHours -ne $defrpo) {
                $rpo = $date.AddHours(-$RPOHours)
            }
            
            foreach ($Job in $Jobs) {
                $lastsession = $allorderdedsess | ? { $_.jobname -eq $Job.Name } | select -First 1
                if ($lastsession -ne $null) {
                   write-sessionrecord -job $Job -session $lastsession
                } else {
                   
                }
            }      
      } else {
       Write-Error "Can not find Jobs with type $jobtype"
      }
  } else {
        Write-Error "Job can only be backup (Backup), backup copy (BackupSync) or replication job (Replica). Cannot be $jt"  
  }
}
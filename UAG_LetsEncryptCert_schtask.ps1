<#
.SYNOPSIS
   Universal script for creating a Windows Scheduled Task for UAG Let's Encrypt Automation.

.DESCRIPTION
   Registers or replaces a Windows Scheduled Task executing UAG_LetsEncryptCert.ps1 in non-interactive mode (-Force).
   Supports Standard Service Accounts (Domain/Local), Current Logged-in User, and gMSA Accounts.

.PREREQUISITES & ACCOUNT TYPES
   1. Standard Service Account (Domain or Local User):
       - Requires an initial interactive logon and creation of the DPAPI-protected credential files under the service account's Windows profile.
       - The account password is requested when registering the task.

   2. gMSA Account (Group Managed Service Account, e.g., DOMAIN\gMSA_Name$):
      - Identified automatically by the trailing '$' character in the account name.
      - Does not require a password prompt during task creation (managed automatically by Active Directory).
      - Requires initial DPAPI credential files to be created under the gMSA security context (e.g., via PsExec).

   3. Current User Context:
      - Registers the task under the currently logged-in user profile using S4U logon type.

.SCHEDULING
    Set the schedule trigger according to the (shorter) certificate lifetime.
    The script renews the certificate only when it is due (Posh-ACME 'RenewAfter', roughly 2/3 of the lifetime) and deploys it to UAG only after a renewal, so frequent runs are harmless.
    The renewal window is only about 1/3 of the lifetime => a frequent check leaves time for retries
    Let's Encrypt certificate lifetime (announced Oct 2026):  until 2027-02-09 = 90 days  |  from 2027-02-10 = 64 days  |  from 2028-02-16 = 45 days
    Tip: set $VAR.EmailOnlyOnEvent = $true in cfg_UAG_LetsEncryptCert.ps1 => email only after a renewal or an error.
    Note: Modern Omnissa UAG versions (v2606+) preserve active user sessions during SSL certificate updates.

.LINK
   https://github.com/jfacz/UAG-Automation

.NOTES
    Version:       2610.0
    Author:        Jan Fara
    Creation Date: 2026-10-31

   [v2610.0 - 20261031] Initial release based on the previous, simplified version of the script.
                        Support for more account types
#>

# Requires Administrator Rights
if(-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Administrator rights are required to run this script! Please re-run PowerShell as Administrator."
    return
}

# ==============================================================================
# Configuration Parameters
# ==============================================================================
$VAR = @{
    # Scheduled Task Name & Description
    SchtaskName          = "UAG-Automation - Let's Encrypt Certificate"
    SchtaskDescription   = "Automated Let's Encrypt SSL Certificate renewal and deployment for UAG appliances (UAG-Automation)"

    # Schedule Trigger Settings (Friday at 01:00 AM every 6 weeks)
    SchtaskWeekDay       = "Friday"
    SchtaskStartTime     = "01:00"
    SchtaskWeeksInterval = 6

    # Target PowerShell Script File (UAG_LetsEncryptCert.ps1) and Config (cfg_UAG_LetsEncryptCert.ps1)
    ScriptPath           = $PSScriptRoot
    ScriptFileName       = "UAG_LetsEncryptCert.ps1"
    ScriptFileConfig     = "cfg_UAG_LetsEncryptCert.ps1"

    # User Account Configuration
    # Options:
    #   1) Current User : "$($env:USERDOMAIN)\$($env:USERNAME)"
    #   2) Service Acc  : "DOMAIN\svc_uag_automation"
    #   3) gMSA Account : "DOMAIN\gMSA_UAG$"
    RunAsUser           = "$($env:USERDOMAIN)\$($env:USERNAME)"
}

# --- Functions ---
# Helper Function to get safe schtask name
Function Get-SafeSchtaskName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )
    # Replace forbidden characters (\/:*?"<>|) with a hyphen 
    $invalidChars = '[\\/:\*\?"<>\|]'
    $safeName = $TaskName -replace $invalidChars, "-"
    # Remove duplicate hyphens and trim spaces.
    $safeName = ($safeName -replace "-+", "-").Trim(" -")
    return $safeName
}

# ==============================================================================
# Main Execution
# ==============================================================================
Clear-Host

# Safe Task Name
$SafeSchtaskName = Get-SafeSchtaskName -TaskName $VAR.SchtaskName
$PSScriptPath = Join-Path $VAR.ScriptPath $VAR.ScriptFileName

Write-Host "***** Creating Scheduled Task: '$($SafeSchtaskName)' *****" -ForegroundColor Cyan
if($SafeSchtaskName -ne $VAR.SchtaskName){
    Write-Host "WARN: Original task name '$($VAR.SchtaskName)' contained invalid characters. Automatically changed to '$($SafeSchtaskName)'." -ForegroundColor Yellow
}

# 1. Verify existence of target script
if(-not (Test-Path $PSScriptPath -PathType Leaf)){
    Write-Error "Target script '$($PSScriptPath)' was not found! Aborting."
    return
}

# 2. Account Type Detection
$isGmsa = $VAR.RunAsUser -like "*$"
$isCurrentUser = ($VAR.RunAsUser -eq "$env:USERDOMAIN\$env:USERNAME") -or ($VAR.RunAsUser -eq $env:USERNAME)

$accountTypeDisplay = if($isGmsa){ "gMSA (Group Managed Service Account)"  } elseif ($isCurrentUser){ "Current Logged-in User Context" } else{ "Dedicated Standard Service Account" }

Write-Host "INFO: Target Account : $($VAR.RunAsUser)"
Write-Host "INFO: Account Type   : $($accountTypeDisplay)"

# 3. Prompt for Password if using a dedicated Standard Service Account
$userPassword =$null
if(-not $isGmsa -and -not $isCurrentUser){
    Write-Host "`nWARN: Registering task for dedicated service account '$($VAR.RunAsUser)'." -ForegroundColor Yellow
    Write-Host "Please enter the password for '$($VAR.RunAsUser)':" -ForegroundColor Yellow
    $secPass = Read-Host -AsSecureString
    $userPassword = [System.Net.NetworkCredential]::new("", $secPass).Password
    if([string]::IsNullOrWhiteSpace($userPassword)){
        Write-Error "Password cannot be empty for standard service account registration! Aborting."
        return
    }
}

# 4. Unregister existing task if present
$existingTask = Get-ScheduledTask -TaskName $SafeSchtaskName -ErrorAction SilentlyContinue
if($existingTask){
    Write-Host "`nINFO: Scheduled task already exists. Replacing existing task..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $SafeSchtaskName -Confirm:$false | Out-Null
}

# 5. Build Action & Arguments
$psExe      = "powershell.exe"
$psArgs     = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($PSScriptPath)`" -ConfigFile `"$($VAR.ScriptFileConfig)`" -Force"
$action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs -WorkingDirectory $VAR.ScriptPath

# 6. Build Trigger (Weekly on specified day and time with custom interval)
$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval $VAR.SchtaskWeeksInterval -DaysOfWeek $VAR.SchtaskWeekDay -At $VAR.SchtaskStartTime

# 7. Build Settings (Allow on battery, limit execution to 2 hours, run later if missed, restart 3x every 30 minutes after a failure)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 30) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -MultipleInstances IgnoreNew

# 8. Register Task based on Account Type
try {
    if($isGmsa){
        # gMSA Account registration (LogonType: ServiceAccount)
        $principal = New-ScheduledTaskPrincipal -UserId $VAR.RunAsUser -LogonType ServiceAccount -RunLevel Highest
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description $VAR.SchtaskDescription
        Register-ScheduledTask -TaskName $SafeSchtaskName -InputObject $definition -Force -ErrorAction Stop | Out-Null
    }
    elseif(-not $isCurrentUser -and $userPassword){
        # Dedicated Service Account with stored credentials
        Register-ScheduledTask -TaskName $SafeSchtaskName -Action $action -Trigger $trigger -Settings $settings -User $VAR.RunAsUser -Password $userPassword -RunLevel Highest -Description $VAR.SchtaskDescription -Force -ErrorAction Stop | Out-Null
    }
    else{
        # Current User registration (S4U LogonType)
        $principal = New-ScheduledTaskPrincipal -UserId $VAR.RunAsUser -LogonType S4U -RunLevel Highest
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description $VAR.SchtaskDescription
        Register-ScheduledTask -TaskName $SafeSchtaskName -InputObject $definition -Force -ErrorAction Stop | Out-Null
    }

    Write-Host "`nSUCCESS: Scheduled Task '$($SafeSchtaskName)' was successfully registered!" -ForegroundColor Green
    Write-Host "Task Summary:"
    Write-Host "  - Task Name     : $($SafeSchtaskName)" -ForegroundColor Gray
    Write-Host "  - Target Script : $($PSScriptPath)" -ForegroundColor Gray
    Write-Host "  - Config File   : $($VAR.ScriptFileConfig)" -ForegroundColor Gray
    Write-Host "  - Working Dir   : $($VAR.ScriptPath)" -ForegroundColor Gray
    Write-Host "  - Schedule      : Every $($VAR.SchtaskWeeksInterval) weeks on $($VAR.SchtaskWeekDay) at $($VAR.SchtaskStartTime)" -ForegroundColor Gray
    Write-Host "  - RunAs Account : $($VAR.RunAsUser) ($accountTypeDisplay)" -ForegroundColor Gray
} catch {
    Write-Error "`nFAILED: Could not register scheduled task! Error details: $($_.Exception.Message)"
} finally {
    # Clean sensitive password variable from memory
    $userPassword =$null
}

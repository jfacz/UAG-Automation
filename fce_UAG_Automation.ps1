<#
.SYNOPSIS
   Shared functions for the UAG-Automation scripts

.DESCRIPTION
   Not a standalone script - it is loaded by the other scripts, which must be kept in the same folder:

.LINK
   https://github.com/jfacz/UAG-Automation

.NOTES
    Version:        2610.0
    Author:         Jan Fara
    Creation Date:  2026-10-31

   [v2610.0 - 20261031] Initial release - functions shared by UAG_Config.ps1, UAG_Deploy.ps1 and UAG_LetsEncryptCert.ps1
#>

# Version of this file - checked by the calling scripts
$FceVersion = "2610.0"

# Default state variables (the calling script can change them after loading this file)
if($null -eq $script:HadError){ $script:HadError = $false }

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Prompts (Read-Host / menu) are possible only in a user session started without -NonInteractive (scheduled task / child process = no prompts)
Function Test-IsInteractive {
    return [bool]([Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^[-/]NonI' }))
}

if($null -eq $script:IsInteractive){ $script:IsInteractive = Test-IsInteractive }

# Function to output messages to the console (optionally with add message to a report - see $script:MsgFceHook)
Function MsgFce {
    param (
        [Parameter(Position=0, Mandatory=$True)] [string] $Msg,
        [ValidateSet("info", "warn", "error", "success", "verbose", "note", "header", "return", "host")] [string] $Output = "info",
        [int] $LinesBefore = 0,
        [int] $LinesAfter = 0,
        [switch] $NoTimeStamp,
        [switch] $NoAddToMail,
        [switch] $NoHtmlStrip
    )

    $Color = switch($Output){
        "warn" {"Yellow"}; "error" {"Red"}; "success" {"Green"}; "verbose" {"Cyan"}; "note" {"DarkGray"}; "header" {"DarkYellow"}
    }

    # Any error message marks the whole run as failed (exit code 1)
    if($Output -eq "error"){ $script:HadError = $true }

    # Hook for a report (e.g. HTML email body) - the original message (with HTML tags)
    if(-not $NoAddToMail -and $script:MsgFceHook -is [scriptblock]){ & $script:MsgFceHook $Msg }

    # Strip Msg from HTML (only if the calling script uses HTML messages)
    if($script:MsgFceStripHtml -and -not $NoHtmlStrip){ $Msg = $Msg -replace '<[^>]*?>','' }
    # Construct message with timestamp
    $Msg = if($NoTimeStamp){ $Msg } else{ "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Msg }
    # Special "return" mode for string returning
    if($Output -eq "return"){ return "`r`n$($Msg)" }

    # Padding: Empty lines before message
    if($LinesBefore -gt 0){ 1..$LinesBefore | ForEach-Object { Write-Host "" } }

    # Console output rendering
    $WriteHostArgs = @{ Object = $Msg }
    if($Color){ $WriteHostArgs.ForegroundColor = $Color }
    if($Output -eq "header"){
        $border = "-" * ($Msg.Length + 4)
        $WriteHostArgs.Object = "$($border)`n  $($Msg.ToUpper())`n$($border)"
        Write-Host @WriteHostArgs
    } else{
        Write-Host @WriteHostArgs
    }
    # Padding: Empty lines after message
    if($LinesAfter -gt 0){ 1..$LinesAfter | ForEach-Object { Write-Host "" } }
}

# Simple choice menu FCE (Writes an output of array items to select)
# Example of use: $MenuItems = @("Yes", "No"); $Title = "Continue?"
Function MenuSimple {
    Param(
        [Parameter(Position=0, Mandatory=$True)] [string[]] $MenuItems,
        [string] $Title,
        [boolean] $Cls,
        [int] $StartFrom = 1
    )

    $header = $null
    if(![string]::IsNullOrWhiteSpace($Title)){
        $len = [math]::Max(($MenuItems | Measure-Object -Maximum -Property Length).Maximum, $Title.Length)
        $header = "{0}{1}{2}" -f $Title, [Environment]::NewLine, ("-" * $len)
    }

    # menu items and space align if more than 9 items
    $maxIndex = $StartFrom + $MenuItems.Count - 1
    $len = if($maxIndex -gt 9){ 2 } else{ 1 }

    # Counter init and generate menu items
    $currentCounter = $StartFrom
    $items = ($MenuItems | ForEach-Object{
        $displayIndex = $currentCounter
        $currentCounter++
        "[{0}]{1}{2}" -f $displayIndex, $(if($displayIndex -lt 10){" " * $len} else{" "}), $_
    }) -join [Environment]::NewLine

    # display the menu and return the chosen option
    while($true){
        if($Cls){ Clear-Host } else{ Write-Host }
        if($header){ Write-Host $header -ForegroundColor Yellow }
        Write-Host $items
        Write-Host
        $index = (Read-Host -Prompt 'Please make your choice')
        $index = $index -as [int]
        # Input validation
        if(($null -ne $index) -and ($StartFrom..$maxIndex) -contains $index){
            return $MenuItems[$index - $StartFrom]
        } else{
            Write-Warning "Invalid choice. Please try again."
            Start-Sleep -Seconds 2
        }
    }
}

# Function for recursive deep merge of two hash tables
Function Merge-Hashtables {
    param (
        [hashtable]$Base,
        [hashtable]$Override
    )
    # If one of the tables is missing, return a clone of the other
    if($null -eq $Base){ return $Override.Clone() }
    if($null -eq $Override){ return $Base.Clone() }

    # Create a shallow copy of the base to write changes into
    $Result = $Base.Clone()

    # Iterate through all keys in the override configuration
    foreach($key in $Override.Keys){
        # If the key exists in both and both values are hash tables, dive deeper
        if($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]){
            $Result[$key] = Merge-Hashtables -Base $Base[$key] -Override $Override[$key]
        } else{
            # Otherwise, simply overwrite/add the value from the override
            $Result[$key] = $Override[$key]
        }
    }

    return $Result
}

# Resolves a secret: value supplied by the caller -> DPAPI file -> interactive prompt (saved via DPAPI).
# Returns SecureString (or plain text with -AsPlainText); $null if the secret is not available (error is reported)
Function Get-DpapiSecret {
    param (
        [Parameter(Mandatory=$true)] [string] $FilePath,
        [Parameter(Mandatory=$true)] [string] $Description,
        [string] $ParamValue,
        [scriptblock] $Validate,
        [switch] $AsPlainText
    )

    # 1. Value supplied by the caller (e.g. script parameter)
    if(-not [string]::IsNullOrWhiteSpace($ParamValue)){
        if($AsPlainText){ return $ParamValue } else{ return (ConvertTo-SecureString $ParamValue -AsPlainText -Force) }
    }

    # 2. DPAPI file
    $secString = $null
    if(Test-Path $FilePath -PathType Leaf){
        try{
            $secString = Get-Content $FilePath -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
            if($secString.Length -eq 0){ throw "Credential file is empty" }
        } catch{
            $secString = $null
            MsgFce "WARN: Credential file '$($FilePath)' ($($Description)) is empty or could not be decrypted via DPAPI (different user/computer?). Re-prompting..." -Output warn -NoTimeStamp -NoAddToMail
            Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
        }
    }
    if($secString){
        if($AsPlainText){ return [System.Net.NetworkCredential]::new("", $secString).Password } else{ return $secString }
    }

    # 3. Interactive prompt with mandatory non-empty check
    if(-not $script:IsInteractive){
        MsgFce "ERROR: Non-interactive execution failed! $($Description) was not provided and DPAPI credential file '$($FilePath)' is missing or unusable. Run the script once interactively under the same account (without -Force) to save it." -Output error -NoTimeStamp
        return $null
    }
    while($true){
        MsgFce "WARN: Credential file '$($FilePath)' does not exist => Please enter $($Description) (it will be saved via DPAPI):" -Output warn -NoTimeStamp -NoAddToMail
        try{
            $secInput = Read-Host -AsSecureString
            $plain = [System.Net.NetworkCredential]::new("", $secInput).Password
            if([string]::IsNullOrWhiteSpace($plain)){
                MsgFce "WARN: Value cannot be empty! Please try again." -Output warn -NoTimeStamp -NoAddToMail
                continue
            }
            if($Validate -and -not (& $Validate $plain)){ continue }
            $secInput | ConvertFrom-SecureString | Out-File $FilePath -ErrorAction Stop
            MsgFce "INFO: $($Description) was successfully saved via DPAPI to '$($FilePath)'" -NoTimeStamp -NoAddToMail
            if($AsPlainText){ return $plain } else{ return $secInput }
        } catch{
            MsgFce "ERROR: Failed to save DPAPI credential for $($Description): $($_.Exception.Message)" -Output error -NoTimeStamp -NoAddToMail
            return $null
        }
    }
}

# Starts transcript logging (only in a console host). Returns $true if the transcript is running
Function Start-ScriptTranscript {
    param (
        [Parameter(Mandatory=$true)] [string] $LogDir,
        [Parameter(Mandatory=$true)] [string] $LogFile
    )

    if($Host.Name -notmatch "ConsoleHost"){ return $false }
    try{
        if(!(Test-Path $LogDir -PathType Container)){ New-Item -Path $LogDir -ItemType Directory -ErrorAction Stop | Out-Null }
        Start-Transcript -Path $LogFile -Force -ErrorAction Stop | Out-Null
        return $true
    } catch{
        Write-Warning "Could not start transcript logging: $($_.Exception.Message). Continuing without logging."
        return $false
    }
}

# Deletes the oldest log files above the limit ($LogFileName = file name template with {0} for the date, e.g. "Script_{0:yyyyMMdd_HHmmss}.txt")
Function Remove-OldLogs {
    param (
        [Parameter(Mandatory=$true)] [string] $LogDir,
        [Parameter(Mandatory=$true)] [string] $LogFileName,
        [Parameter(Mandatory=$true)] [int] $Keep
    )

    if($Keep -le 0 -or -not (Test-Path $LogDir -PathType Container)){ return }
    $logFilter = $LogFileName -replace '\{0.*?\}', '*'
    $logFiles  = @(Get-ChildItem -Path $LogDir -Filter $logFilter -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    if($logFiles.Count -gt $Keep){
        MsgFce "INFO: Log archive limit exceeded ($($logFiles.Count)/$($Keep)) => Deleting oldest log files" -LinesBefore 1 -NoAddToMail
        $logFiles | Sort-Object LastWriteTime | Select-Object -First ($logFiles.Count - $Keep) | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Checks SSL Certificate expiration date against warning threshold
Function Test-CertificateExpiry {
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $CertObject,
        [string] $CertName,
        [int] $WarnDays = 30
    )

    $now = Get-Date
    $daysLeft = ($CertObject.NotAfter - $now).Days

    if($now -lt $CertObject.NotBefore){
        MsgFce "ERROR: Certificate '$($CertName)' is NOT YET VALID! (Valid from: $($CertObject.NotBefore))" -Output error -NoTimeStamp
        return $false
    } elseif($daysLeft -le 0){
        MsgFce "ERROR: Certificate '$($CertName)' EXPIRED on $($CertObject.NotAfter)!" -Output error -NoTimeStamp
        return $false
    } elseif($daysLeft -le $WarnDays){
        MsgFce "WARN: Certificate '$($CertName)' expires in $($daysLeft) days ($($CertObject.NotAfter.ToString('yyyy-MM-dd')))" -Output warn -NoTimeStamp
    } else{
        MsgFce "INFO: Certificate '$($CertName)' is valid ($($daysLeft) days remaining, expires: $($CertObject.NotAfter.ToString('yyyy-MM-dd')))" -NoTimeStamp
    }
    return $true
}

# Throws an error if the configuration (hashtable / array / string, nested) contains an unfilled placeholder '<...>'
# Example: Confirm-NoPlaceholders -Data $CFG_UAG -Path "CFG_UAG" -Context "UAG deployment configuration"
Function Confirm-NoPlaceholders {
    param (
        [Parameter(Mandatory=$true)] $Data,
        [Parameter(Mandatory=$true)] [string] $Path,
        [string] $Context = "configuration",
        $Found   # internal (recursion): list of paths found so far
    )

    $isTop = $null -eq $Found
    if($isTop){ $Found = [System.Collections.Generic.List[string]]::new() }

    if($Data -is [System.Collections.IDictionary]){
        foreach($key in $Data.Keys){ Confirm-NoPlaceholders -Data $Data[$key] -Path "$($Path).$($key)" -Found $Found }
    } elseif($Data -is [array]){
        for($i = 0; $i -lt $Data.Count; $i++){ Confirm-NoPlaceholders -Data $Data[$i] -Path "$($Path)[$($i)]" -Found $Found }
    } elseif($Data -is [string] -and $Data -match '<.+>'){
        $Found.Add($Path)
    }

    if($isTop -and $Found.Count -gt 0){ throw "ERROR: Unfilled placeholder '<...>' in $($Context): $($Found -join '; ')" }
}

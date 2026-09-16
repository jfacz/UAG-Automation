<#
.SYNOPSIS
   Automated REST API management script for Omnissa Unified Access Gateway (UAG).

.DESCRIPTION
   Configures system settings, Horizon Edge services, RADIUS SAML, SSL certificates and Syslog, and local users
   on target Omnissa UAG appliances via REST API using DPAPI-secured credentials.

.PROJECTURI https://github.com/jfacz/UAG-Automation

.NOTES
    Version:        2609.0
    Author:         Jan Fara
    Creation Date:  2026-08-28
    Last Update:    2026-09-16

.RELEASENOTES
   [v2609.0 - 20260916] Added support for silent execution from UAG deploy script (with Transcript logging)
                        Added support for SAML and RADIUS authentification with stording shared secrets via DPAPI
                        Added support for local user accounts creation/updates via REST API 
                        Bug fixes and stability improvements
   [v2608.0 - 20260828] Rewrote the previous simpler version of the script for UAG upload PEM certificate
                        UAG configuration in separate file
                        Added support for upload PFX certificate to UAG
                        Added secret storing UAG Admin passwords via DPAPI

.EXAMPLE
    # Execute interactive configuration menu
    .\UAG_API_Manage.ps1

.EXAMPLE
    # Execute automated silent configuration with static certificate defined in cfg_UAG.ps1
    .\UAG_API_Manage.ps1 -Mode CfgConfigAndCert -TargetUAG "UAG-EXT-01" -CertName "vdi.company.com [PFX]" -CertPfxPassword "SecretPass123"

.EXAMPLE
    # Upload PEM/PFX certificate via CLI parameters
    .\UAG_API_Manage.ps1 -Mode CfgCertOnly -TargetUAG ALL -CertPem "C:\Cert\fullchain.pem" -CertKeyPem "C:\Cert\privkey.pem"
    .\UAG_API_Manage.ps1 -Mode CfgCertOnly -TargetUAG "UAG-EXT-01" -CertPfxPath "C:\Cert\vdi.pfx" -CertPfxPassword "SecretPass123"
#>

# ==============================================================================
# Script Parameters
# ==============================================================================
param (
    [Parameter(Mandatory=$false, HelpMessage="Path to file with UAG Config Definition")]
    [string] $UagCfg = "cfg_UAG.ps1",

    [Parameter(Mandatory=$false, HelpMessage="Script execution mode")]
    [ValidateSet("CfgConfigAndCert", "CfgConfigOnly", "CfgCertOnly")]
    [string] $Mode,

    [Parameter(Mandatory=$false, HelpMessage="Target UAG name or 'ALL'")]
    [string] $TargetUAG,

    # --- Certificate Parameters ---
    [Parameter(Mandatory=$false, HelpMessage="Certificate key name from Certificate hashtable or custom dynamic label")]
    [string] $CertName,

    [Parameter(Mandatory=$false, HelpMessage="Certificate Type (PEM or PFX)")]
    [ValidateSet("PEM", "PFX")]
    [string] $CertType,

    [Parameter(Mandatory=$false, HelpMessage="Path to PEM Certificate full chain file")]
    [string] $CertPem,

    [Parameter(Mandatory=$false, HelpMessage="Path to PEM Private Key file")]
    [string] $CertKeyPem,

    [Parameter(Mandatory=$false, HelpMessage="Path to PFX Certificate file")]
    [string] $CertPfxPath,

    [Parameter(Mandatory=$false, HelpMessage="Optional PFX Alias")]
    [string] $CertPfxAlias,

    [Parameter(Mandatory=$false, HelpMessage="PFX Password for silent execution or dynamic upload")]
    [string] $CertPfxPassword,

    [Parameter(Mandatory=$false, HelpMessage="Target UAG Entity listener (end_user | admin)")]
    [string[]] $CertEntity = @("end_user"),

    # --- RADIUS Secret Parameters ---
    [Parameter(Mandatory=$false, HelpMessage="Optional Primary RADIUS Secret for silent execution")]
    [string] $RadiusSecret,

    [Parameter(Mandatory=$false, HelpMessage="Optional Secondary RADIUS Secret for silent execution")]
    [string] $RadiusSecret2
)

# ==============================================================================
# SETTINGS
# ==============================================================================
$VAR = @{
 # Script Name
  ScriptName = "UAG API Manager"
 # Script Path ($PSScriptRoot for current folder)
  ScriptPath = $PSScriptRoot

 # --- API NETWORK & RETRY SETTINGS ---
  UagApiPort = 9443
 # Timeout in seconds to wait/check if UAG API is ready
  UagWaitTimeout = 120
  ApiMaxRetries  = 3   # Maximum attempts per API call if network socket drops
  ApiRetryDelay  = 3   # Delay in seconds between failed retry attempts
  ApiStepDelay   = 1   # Settling delay in seconds between steps for UAG daemons

 # --- SECURITY ---
  ExpiryWarnDays = 30  # Number of days to warn before upcoming expiration (SSL cert and SAML metadata)
 # Credential files for UAG and RADIUS (stored via DPAPI per computer and user)
  SecCredUAG     = "sec_uag_{0}_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  SecCredRadius1 = "sec_radius_primary_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  SecCredRadius2 = "sec_radius_secondary_$($env:COMPUTERNAME)_$($env:USERNAME).txt"

 # --- LOG SETTINGS ---
  LogOnlyIfSilent = $true
  LogDir          = "Logs"
  LogFileName     = "UAG_API_Manage_{0:yyyyMMdd_HHmmss}.txt"
  LogArchiveFiles = 6

  # Debug mode (for more verbose output)
  DEBUG = $false
}

# ==============================================================================

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Function to output messages to the console
Function MsgFce {
    param (
        [Parameter(Position=0, Mandatory=$True)] [string] $Msg,
        [ValidateSet("info", "warn", "error", "success", "verbose", "note", "header", "return")] [string] $Output="info",
        [int] $LinesBefore=0,
        [int] $LinesAfter=0,
        [switch] $NoTimeStamp
    )
 
    $Color = switch($Output){ 
        "warn" {"Yellow"}; "error" {"Red"}; "success" {"Green"}; "verbose" {"Cyan"}; "note" {"DarkGray"}; "header" {"DarkYellow"} 
    }
    # Padding: Empty lines before output
    if($LinesBefore){ 1..$LinesBefore | ForEach-Object{ Write-Host "" } }
    # Construct message with timestamp
    $Msg = if($NoTimeStamp){ $Msg } else{ "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Msg }
    if($Output -eq "return"){ return "`r`n$($Msg)" }

    # Output to console
    $WriteHostArgs = @{ Object = $Msg }
    if($Color){ $WriteHostArgs.ForegroundColor = $Color }
    if($Output -eq "header"){
        $border = "-" * ($Msg.Length + 4)
        $WriteHostArgs.Object = "$($border)`n  $($Msg.ToUpper())`n$($border)"
        Write-Host @WriteHostArgs
    } else{
        Write-Host @WriteHostArgs
    }
    # Padding: Empty lines after output
    if($LinesAfter){ 1..$LinesAfter | ForEach-Object { Write-Host "" } }
}

# Simple choice menu FCE (Writes an output of array items to select)
# Example of use: $MenuItems = @("Yes", "No"); $Title = "Continue?"
function MenuSimple {
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
        if(($StartFrom..$maxIndex) -contains $index){
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

# Checks SSL Certificate expiration date against warning threshold
Function Test-UagCertExpiry {
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

# Checks expiration date of SAML Metadata (validUntil attribute & embedded X.509 certificates)
Function Test-SamlMetadataExpiry {
    param (
        [Parameter(Mandatory=$true)]
        [string] $XmlPath,
        [int] $WarnDays = 30
    )

    try{
        [xml]$xml = Get-Content -Path $XmlPath -Raw -ErrorAction Stop
        $now = Get-Date

        # 1. Check 'validUntil' XML attribute (e.g. Google SAML)
        $validUntilAttr = $xml.SelectSingleNode("//*[@validUntil]")
        if($validUntilAttr -and $validUntilAttr.validUntil){
            $validUntilDate = [DateTime]::Parse($validUntilAttr.validUntil)
            $daysLeft = ($validUntilDate - $now).Days
            if($now -gt $validUntilDate){
                MsgFce "ERROR: SAML Metadata 'validUntil' EXPIRED on $($validUntilDate.ToString('yyyy-MM-dd HH:mm:ss'))!" -Output error -NoTimeStamp
                return $false
            } elseif($daysLeft -le $WarnDays){
                MsgFce "WARN: SAML Metadata 'validUntil' expires in $($daysLeft) days ($($validUntilDate.ToString('yyyy-MM-dd')))" -Output warn -NoTimeStamp
            } else{
                MsgFce "INFO: SAML Metadata 'validUntil' is valid ($($daysLeft) days remaining, expires: $($validUntilDate.ToString('yyyy-MM-dd')))" -NoTimeStamp
            }
        }

        # 2. Check embedded X.509 certificates (e.g. Entra ID)
        $certNodes = $xml.SelectNodes("//*[local-name()='X509Certificate']")
        if($certNodes -and $certNodes.Count -gt 0){
            foreach($node in $certNodes){
                $cleanCert = $node.InnerText -replace '\s',''
                if(-not [string]::IsNullOrWhiteSpace($cleanCert)){
                    $certBytes = [System.Convert]::FromBase64String($cleanCert)
                    $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$certBytes)
                    if(-not (Test-UagCertExpiry -CertObject $certObj -CertName "SAML Embedded Cert" -WarnDays $WarnDays)){
                        return $false
                    }
                }
            }
        }
        return $true
    } catch{
        MsgFce "WARN: Could not parse SAML Metadata expiration details: $($_.Exception.Message)" -Output warn -NoTimeStamp
        return $true # Fallback: Do not block deployment if XML has a non-standard structure
    }
}

# Prepares API request data for UAG REST API deployment
Function Get-UagCertApiData {
    param (
        [Parameter(Mandatory=$true)]
        [hashtable] $CertDef
    )

    # Resolve target listener entities (supports CertEntity / UagEntity with fallback to 'end_user')
    [string[]]$entities = if($CertDef.CertEntity){ $CertDef.CertEntity } elseif($CertDef.UagEntity){ $CertDef.UagEntity } else{ @("end_user") }
    foreach($e in $entities){
        if($e -notin @("end_user", "admin")){ throw "Invalid target entity '$($e)'! Allowed values are only 'end_user' or 'admin'" }
    }

    $bodyData = $null
    $baseEndpoint = $null

    # --- PEM Format ---
    if($CertDef.CertType -eq "PEM"){
        $certPemPath = $CertDef.CertPem
        $keyPemPath  = $CertDef.CertKeyPem
        if(-not (Test-Path $certPemPath) -or -not (Test-Path $keyPemPath)){ throw "PEM certificate or private key file was not found!" }

        # Check Expiration for PEM
        $pemCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPemPath)
        if(-not (Test-UagCertExpiry -CertObject $pemCertObj -CertName $certPemPath -WarnDays $VAR.ExpiryWarnDays)){ throw "Certificate expiration check failed!" }

        $baseEndpoint = "/rest/v1/config/certs/ssl"
        $bodyData = @{
            certChainPem  = [IO.File]::ReadAllText($certPemPath).Replace(([char]0xFEFF).ToString(), "")
            privateKeyPem = [IO.File]::ReadAllText($keyPemPath).Replace(([char]0xFEFF).ToString(), "")
        }
    }
    # --- PFX Format ---
    elseif($CertDef.CertType -eq "PFX"){
        $pfxPath  = $CertDef.CertPfxPath
        $pfxAlias = $CertDef.CertPfxAlias
        if(-not (Test-Path $pfxPath)){ throw "PFX file '$($pfxPath)' was not found!" }

        # PFX Password resolution (Parameter -> Interactive Prompt)
        if($CertPfxPassword){
            $passPlain = $CertPfxPassword
        } elseif($isSilent){
            throw "ERROR: Silent execution failed! PFX certificate '$($pfxPath)' requires a password, but '-CertPfxPassword' parameter was not provided."
        } else{
            MsgFce "Enter password for PFX certificate '$($pfxPath)':"
            $passSec = Read-Host -AsSecureString
            $passPlain = [System.Net.NetworkCredential]::new("", $passSec).Password
        }

        # Local validation: Password, Private Key & Expiration
        try{
            $pfxCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $pfxPath, $passPlain
            if(-not $pfxCertObj.HasPrivateKey){ throw "PFX file does not contain a private key!" }
            if(-not (Test-UagCertExpiry -CertObject $pfxCertObj -CertName $pfxPath -WarnDays $VAR.ExpiryWarnDays)){ throw "Certificate expiration check failed!" }
        } catch{
            $passPlain = $null
            throw "Failed to open or validate PFX certificate! Error: $($_.Exception.Message)"
        }

        # Read raw bytes and convert to Base64 string
        $pfxBytes  = [System.IO.File]::ReadAllBytes($pfxPath)
        $pfxBase64 = [System.Convert]::ToBase64String($pfxBytes)

        $baseEndpoint = "/rest/v1/config/certs/ssl/pfx"

        # Build JSON body without empty 'alias' key
        $bodyData = [ordered] @{
            pfxKeystore = $pfxBase64
            password    = $passPlain
        }
        if(-not [string]::IsNullOrWhiteSpace($pfxAlias)){
            $bodyData["alias"] = $pfxAlias
        }

        $passPlain = $null
    } else {
        throw "Unknown certificate type '$($CertDef.CertType)' (supported: 'PEM' and 'PFX')"
    }

    # Generate request objects array for each target entity
    $requests = @()
    foreach($entity in $entities){
        $requests += @{
            Entity   = $entity
            Endpoint = "$baseEndpoint/$entity"
            Data     = $bodyData
        }
    }
    return $requests
}

# Reads a PEM file, strips BOM, and extracts all X.509 certificate blocks
Function Get-PemContentFromFile {
    param (
        [Parameter(Mandatory=$true)]
        [string] $FilePath
    )

    if(-not (Test-Path -Path $FilePath -PathType Leaf)){ return $null }

    $rawText = [System.IO.File]::ReadAllText((Resolve-Path $FilePath).Path).Replace(([char]0xFEFF).ToString(), "")
    $certMatches = [regex]::Matches($rawText, '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----')
    if($certMatches.Count -gt 0){
        return ($certMatches | ForEach-Object { $_.Value }) -join "`n"
    } else{
        return $rawText.Trim()
    }
}

# Extract REST API error response body
Function Get-RestErrorResponse {
    param ([Parameter(Mandatory=$true)] $ErrorRecord)
    try {
        # PowerShell 7+
        if($ErrorRecord.ErrorDetails.Message){
            return $ErrorRecord.ErrorDetails.Message
        }
        # PowerShell 5.1
        if($ErrorRecord.Exception.Response){
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($stream)
            return $reader.ReadToEnd()
        }
    } catch {
        return $null
    }
    return $null
}

# Password Complexity Checker for UAG local accounts
Function Test-UAGPasswordStrength {
    param(
        [Parameter(Mandatory=$true)] [string]$Password,
        [Parameter(Mandatory=$true)] [string]$Username,
        [int]$MinLength = 8
    )

    if([string]::IsNullOrWhiteSpace($Password)){
        MsgFce "ERROR: Password for user '$($Username)' cannot be empty!" -Output error
        return $false
    }
    if($Password.Length -lt $MinLength){
        MsgFce "ERROR: Password for user '$($Username)' must have at least $($MinLength) characters (current: $($Password.Length))!" -Output error
        return $false
    }
    # Check for forbidden/problematic characters in UAG API (like '+' or spaces)
    if($Password -match '[\s+\=\"'']'){
        MsgFce "ERROR: Password for user '$($Username)' contains invalid characters (do not use +, spaces, =, or quotes)!" -Output error
        return $false
    }
    # Validate all 4 required character classes for UAG REST API
    $hasUpper   = $Password -match '[A-Z]'
    $hasLower   = $Password -match '[a-z]'
    $hasDigit   = $Password -match '\d'
    $hasSpecial = $Password -match '[!@#$%^&*()_+\-=\[\]{};:"\\|,.<>/?]'

    if(-not ($hasUpper -and $hasLower -and $hasDigit -and $hasSpecial)){
        MsgFce "ERROR: Password for user '$($Username)' must contain characters from all 4 classes: Uppercase, Lowercase, Digit, and Special character!" -Output error
        return $false
    }
    #if($Password.ToLower().Contains($Username.ToLower())){
    #    MsgFce "ERROR: Password for user '$($Username)' must not contain the username itself!" -Output error
    #    return $false
    #}
    return $true
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------
$isSilent = [bool]($Mode -or $TargetUAG -or $CertPem -or $CertPfxPath)
$shouldLog = (-not $VAR.LogOnlyIfSilent) -or $isSilent
$LogDir  = Join-Path $VAR.ScriptPath $VAR.LogDir
$LogFile = (Join-Path $LogDir $VAR.LogFileName) -f (Get-Date)

# Ignore invalid SSL certificates during API calls & set TLS 1.2
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
if($Host.Name -match "ConsoleHost" -and $shouldLog){
    try{
        if(!(Test-Path $LogDir -PathType Container)){ New-Item -Path $LogDir -ItemType Directory | Out-Null }
        Start-Transcript -Path $LogFile -Force -ErrorAction Stop | Out-Null
    } catch{
        Write-Warning "Could not start transcript logging: $($_.Exception.Message). Continuing without logging."
        $shouldLog = $false
    }
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
Try{
    if(-not $isSilent){ Clear-Host }
    MsgFce "***** The beginning of the script '$($VAR.ScriptName)' *****" -Output note -LinesAfter 1

    # --- Verifying configuration and loading UAG CFG ---
    if($VAR.SecCredUAG -like ""){
        MsgFce "ERROR: Incomplete configuration of security credential files!" -Output error
        return
    }

    if(-not [System.IO.Path]::IsPathRooted($UagCfg)){ $UagCfg = Join-Path $PSScriptRoot $UagCfg } # relative path -> absolute path
    # Resolve and validate path
    try{
        $UagCfg = (Resolve-Path -LiteralPath $UagCfg -ErrorAction Stop).Path
    } catch{
        MsgFce "ERROR: Unable to load UAG configuration. File '$($UagCfg)' doesn't exist!" -Output error
        return
    }
    # Load & Validate Cfg
    . $UagCfg
    if($UAG_CFG -isnot [hashtable]){
        MsgFce "ERROR: Configuration '`$UAG_CFG' is not a hashtable!" -Output error
        return
    }

    # Global UAG Configuration check
    if(-not $UAG_CFG.ContainsKey("ALL")){
        MsgFce "ERROR: Global default 'ALL' configuration template not found in configuration Hash Table!" -Output error
        return
    }

    # --- Execution Mode Selection ---
    if($Mode){
        MsgFce "Script execution mode set via parameter: '$($Mode)'" -NoTimeStamp
        $doConfig = $Mode -in @("CfgConfigAndCert", "CfgConfigOnly")
        $doCert   = $Mode -in @("CfgConfigAndCert", "CfgCertOnly")
    } else{
        $mTitle = "Select script execution mode"
        $mOpts = @("Exit", "UAG Config + SSL Certificate", "UAG Config Only", "SSL Certificate only")
        $mMode = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
        if($mMode -like "Exit"){
            MsgFce "WARN: Terminated by user (exit)" -Output warn -NoTimeStamp
            return
        } else{
            MsgFce "Selected mode: '$($mMode)'" -NoTimeStamp
        }
        $doConfig = if($mMode -like "*UAG Config*"){ $true } else { $false }
        $doCert   = if($mMode -like "*SSL Certificate*"){ $true } else { $false }
    }

    # --- Target UAG Selection ---
    if($TargetUAG){
        if($TargetUAG -eq "ALL"){
            $selUAG = $UAG
        } else{
            $selUAG = $UAG | Where-Object { $_.Name -eq $TargetUAG }
            if(-not $selUAG){ throw "ERROR: Target UAG '$($TargetUAG)' not found in inventory!" }
        }
        MsgFce "Target UAG set via parameter: '$($TargetUAG)'" -NoTimeStamp
    } elseif($UAG.Count -eq 1){
        # Auto-select if only 1 UAG appliance is defined in $UAG inventory
        $selUAG = $UAG
        MsgFce "INFO: Single UAG appliance detected in inventory. Automatically selected: '$($selUAG[0].Name)'" -NoTimeStamp -LinesBefore 1
    } elseif($isSilent){
        # Safety Fail-Safe: Require explicit -TargetUAG parameter when multiple UAGs exist
        throw "ERROR: Silent execution failed! Multiple UAG appliances found in inventory, but '-TargetUAG' parameter was not specified. Specify '-TargetUAG ALL' or provide a specific UAG name."
    } else{
        $mTitle = "Select target UAG to apply"
        $mOpts = @("Exit", "ALL") + ($UAG | ForEach-Object { "$($_.Name)" })
        $mSelUAG = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
        if($mSelUAG -like "Exit"){
            MsgFce "WARN: Terminated by user (exit)" -Output warn -NoTimeStamp
            return
        } else{
            MsgFce "Selected UAG: '$($mSelUAG)'" -NoTimeStamp
        }
        $selUAG = if($mSelUAG -like "ALL"){ $UAG } else { $UAG | Where-Object { $_.Name -eq $mSelUAG }}
    }

    # --- SSL Certificate Selection (Static vs. Dynamic CLI) ---
    if($doCert){
        # Option A: Dynamic CLI certificate upload (e.g. Let's Encrypt / ACME renewal hook)
        if($CertPem -or $CertPfxPath){
            $resolvedType = if($CertType){ $CertType } elseif($CertPfxPath){ "PFX" } else { "PEM" }
            $mSelCert = if($CertName){ $CertName } else { "Dynamic CLI Certificate ($(Get-Date -Format 'yyyy-MM-dd'))" }
            $dynamicCertDef = @{
                CertType      = $resolvedType
                CertPem       = $CertPem
                CertKeyPem    = $CertKeyPem
                CertPfxPath   = $CertPfxPath
                CertPfxAlias  = $CertPfxAlias
                CertEntity    = $CertEntity
            }
            MsgFce "INFO: Using dynamic certificate supplied via CLI parameters (Format: $($resolvedType))" -NoTimeStamp
            $certRequests = Get-UagCertApiData -CertDef $dynamicCertDef
        }
        # Option B: Static configuration from cfg_UAG.ps1 ($CERTS hashtable)
        else{
            if($null -eq $CERTS -or $CERTS.Count -eq 0){ throw "ERROR: No certificate defined in '`$CERTS' hashtable!" }
            if($CertName){
                if(-not $CERTS.ContainsKey($CertName)){ throw "ERROR: Certificate '$($CertName)' was not found in `$CERTS hashtable!" }
                $mSelCert = $CertName
                MsgFce "Certificate set via parameter: '$($CertName)'" -NoTimeStamp
            } elseif($CERTS.Count -eq 1){
                 # Auto-select if only 1 certificate is defined in $CERTS hashtable
                $mSelCert = $CERTS.Keys | Select-Object -First 1
                MsgFce "INFO: Single certificate detected in `$CERTS. Automatically selected: '$($mSelCert)'" -NoTimeStamp -LinesBefore 1
            } elseif($isSilent){
                # Safety Fail-Safe: Require explicit -CertName parameter when multiple certificates exist
                throw "ERROR: Silent execution failed! Multiple certificates found in `$CERTS, but '-CertName' parameter was not provided."
            } else{
                $mTitle = "Select SSL Certificate to apply"
                $mOpts = @("Exit") + ($CERTS.Keys | Sort-Object)
                $mSelCert = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
                if($mSelCert -like "Exit"){
                    MsgFce "WARN: Terminated by user (exit)" -Output warn -NoTimeStamp
                    return
                } else{
                    MsgFce "Selected certificate: '$($mSelCert)'" -NoTimeStamp
                }
            }
            # Prepare array of API request objects
            $certRequests = Get-UagCertApiData -CertDef $CERTS[$mSelCert]
        }
    }

    # --- Interactive Safety Confirmation Prompt ---
    if(-not $isSilent){
        MsgFce "Summary of execution parameters:" -Output verbose -NoTimeStamp -LinesBefore 1
        MsgFce "  - Execution Mode: $mMode" -NoTimeStamp
        MsgFce "  - Target UAG(s):  $($selUAG.Name -join ', ')" -NoTimeStamp
        if($doCert){ MsgFce "  - SSL Certificate: $mSelCert" -NoTimeStamp }
        
        $confirm = MenuSimple -MenuItems @("No", "Yes") -Title "Do you want to proceed with UAG REST API configuration?" -StartFrom 0
        if($confirm -ne "Yes"){
            MsgFce "WARN: Configuration aborted by user." -Output warn -LinesBefore 1 -NoTimeStamp
            return
        }
    }

    # UAG API Steps for configuration
    $API_Steps = @(
        @{ Name = "System settings";     ConfigKey = "systemSettings"; Endpoint = "/rest/v1/config/system" }
        @{ Name = "General settings";    ConfigKey = "uagSettings";    Endpoint = "/rest/v1/config/settings" }
        @{ Name = "RADIUS Auth";         ConfigKey = "radiusSettings"; Endpoint = "/rest/v1/config/authmethod/radius-auth" }
        @{ Name = "SAML IdP Metadata";   ConfigKey = "samlSettings";   Endpoint = "/rest/v1/config/idp-ext-metadata" }
        @{ Name = "Horizon Edge (View)"; ConfigKey = "edgeService";    Endpoint = "/rest/v1/config/edgeservice/view" }
        @{ Name = "Syslog settings";     ConfigKey = "syslogSettings"; Endpoint = "/rest/v1/config/syslog" }
        @{ Name = "Users settings";      ConfigKey = "adminUsers";     Endpoint = "/rest/v1/config/adminusers" }
    )

    # --- Process each selected UAG ---
    foreach($uag in $selUAG){
        MsgFce "INFO: API configuration of UAG '$($uag.Name)' (IP: $($uag.IP))..." -Output verbose -LinesBefore 1

        # Check/Wait for UAG API Port availability
        $timeout = $VAR.UagWaitTimeout
        MsgFce "INFO: Checking if UAG '$($uag.Name)' ($($uag.IP):$($VAR.UagApiPort)) is ready (up to $($timeout)s)..."
        $waitInterval = 5
        $portReady = $false
        while($timeout -gt 0){
            try{
                $tcp = New-Object System.Net.Sockets.TcpClient
                $asyncConnect = $tcp.BeginConnect($uag.IP, $VAR.UagApiPort, $null, $null)
                $waitSuccess = $asyncConnect.AsyncWaitHandle.WaitOne(1000, $false)
                if($waitSuccess -and $tcp.Connected){
                    $tcp.Close()
                    $portReady = $true
                    break
                }
                $tcp.Close()
            } catch { }

            MsgFce "Waiting... UAG '$($uag.Name)' ($($uag.IP):$($VAR.UagApiPort)) is not ready yet. Next check in $($waitInterval)s (Timeout in $($timeout)s)." -Output note
            Start-Sleep -Seconds $waitInterval
            $timeout -= $waitInterval
        }

        if (-not $portReady) {
            MsgFce "ERROR: Timeout waiting for UAG '$($uag.Name)' ($($uag.IP):$($VAR.UagApiPort)) to become ready. Skipping..." -Output error
            continue
        }
        MsgFce "SUCCESS: UAG '$($uag.Name)' ($($uag.IP):$($VAR.UagApiPort)) is online and ready" -Output success

        # DPAPI Authorization for UAG Admin
        $SecCredUAG = Join-Path $VAR.ScriptPath ($VAR.SecCredUAG -f ($uag.Name))
        $passwSec = $null
        if(Test-Path $SecCredUAG -PathType Leaf){
            try{
                $passwSec = Get-Content $SecCredUAG | ConvertTo-SecureString -ErrorAction Stop
            } catch{
                MsgFce "WARN: Credential file '$($SecCredUAG)' could not be decrypted. Re-prompting..." -Output warn
                Remove-Item $SecCredUAG -Force -ErrorAction SilentlyContinue
            }
        }

        # If credential file doesn't exist or decryption failed, prompt for it
        if(!(Test-Path $SecCredUAG -PathType Leaf)){
            if($isSilent){
                MsgFce "ERROR: Silent execution failed for UAG '$($uag.Name)'! Password file '$($SecCredUAG)' does not exist. Run interactively first to save credentials." -Output error
                continue
            }
            MsgFce "WARN: Password file $($SecCredUAG) for UAG '$($uag.Name)' (IP: $($uag.IP)) does not exist => Please enter password for user '$($uag.User)' (it will be saved via DPAPI):" -Output warn
            try{
                # Read and encrypt input using DPAPI
                Read-Host -AsSecureString | ConvertFrom-SecureString | Out-File $SecCredUAG -ErrorAction Stop
                MsgFce "INFO: Password for UAG '$($uag.Name)' was successfully saved"
                $passwSec = Get-Content $SecCredUAG | ConvertTo-SecureString -ErrorAction Stop
            } catch{
                MsgFce "ERROR: Failed to save password for UAG '$($uag.Name)': $($_.Exception.Message)" -Output error
                continue
            }
        }

        # UAG Authorization header
        $uagCred = [System.Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $uag.User,([System.Net.NetworkCredential]::new("",$passwSec).Password))))
        $uagAuthHeader = @{"Authorization" = "Basic $($uagCred)" }

        # Base API URI for UAG
        $uribase = "https://$($uag.IP):$($VAR.UagApiPort)"

        # UAG API Configuration
        if($doConfig){
            # Configuration Merging
            $cfguag = $UAG_CFG["ALL"].Clone()
            if($UAG_CFG.ContainsKey($uag.Name)){
                MsgFce "INFO: Custom overrides found for UAG '$($uag.Name)'. Merging configurations..."
                $cfguag = Merge-Hashtables -Base $cfguag -Override $UAG_CFG[$uag.Name]
            } else{
                MsgFce "INFO: No overrides found for UAG '$($uag.Name)'. Deploying global (standard) configuration..."
            }

            foreach($step in $API_Steps){
                $configData = $cfguag[$step.ConfigKey]
                if($null -eq $configData -or $configData.Count -eq 0){ continue }

                # Base URI for current API step
                $uri = $uribase + $step.Endpoint

                # Safe copy of configuration dictionary
                $stepData = @{}
                foreach ($k in $configData.Keys) { $stepData[$k] = $configData[$k] }

                # Horizon Edge Service (View) Certificate Resolution
                if($step.ConfigKey -eq "edgeService"){
                    # 1. Trusted CA Certificates (Array of PEM files)
                    if($stepData.ContainsKey("trustedCertificates") -and $stepData["trustedCertificates"]){
                        $parsedCerts = @()
                        foreach($path in $stepData["trustedCertificates"]){
                            if(-not [string]::IsNullOrWhiteSpace($path)){
                                $pemContent = Get-PemContentFromFile -FilePath $path
                                if($pemContent){
                                    $parsedCerts += @{
                                        name = [System.IO.Path]::GetFileName($path)
                                        data = $pemContent
                                    }
                                } else{
                                    MsgFce "ERROR: Trusted CA certificate file '$($path)' was not found!" -Output error
                                }
                            }
                        }
                        $stepData["trustedCertificates"] = $parsedCerts
                    }

                    # 2. Proxy Blast & Tunnel PEM Certificates (Single or Multi PEM file per property)
                    foreach($certProp in @("proxyBlastPemCert", "proxyTunnelPemCert")){
                        if($stepData.ContainsKey($certProp) -and -not [string]::IsNullOrWhiteSpace($stepData[$certProp])){
                            $path = $stepData[$certProp]
                            $pemContent = Get-PemContentFromFile -FilePath $path
                            if($pemContent){
                                $stepData[$certProp] = $pemContent
                            } else{
                                MsgFce "ERROR: Certificate file '$($path)' for '$($certProp)' was not found!" -Output error
                            }
                        }
                    }
                }

                # RADIUS Shared Secrets resolution (Parameter -> DPAPI File -> Interactive Prompt)
                if($step.ConfigKey -eq "radiusSettings" -and ($stepData["enabled"] -eq $true -or $stepData["enabled"] -eq "true")){
                    # Primary RADIUS Secret
                    if([string]::IsNullOrWhiteSpace($stepData["sharedSecret"])){
                        $fileRad1 = Join-Path $VAR.ScriptPath $VAR.SecCredRadius1
                        $rad1Pass = $null
                        if($RadiusSecret){
                            $rad1Pass = $RadiusSecret
                        } elseif(Test-Path $fileRad1 -PathType Leaf){
                            try{
                                $secStr = Get-Content $fileRad1 | ConvertTo-SecureString -ErrorAction Stop
                                $rad1Pass = [System.Net.NetworkCredential]::new("", $secStr).Password
                            } catch{
                                MsgFce "WARN: Primary RADIUS credential file '$($fileRad1)' could not be decrypted. Re-prompting..." -Output warn
                                Remove-Item $fileRad1 -Force -ErrorAction SilentlyContinue
                            }
                        }
                        
                        # Interactive prompt loop with mandatory non-empty check
                        while([string]::IsNullOrWhiteSpace($rad1Pass)){
                            if($isSilent){
                                MsgFce "ERROR: Silent execution failed for UAG '$($uag.Name)'! RADIUS Auth is enabled, but Primary Shared Secret was not provided via '-RadiusSecret' parameter and DPAPI file '$($fileRad1)' is missing or empty." -Output error
                                break
                            } else{
                                MsgFce "Enter Primary RADIUS Shared Secret for UAG '$($uag.Name)' (it will be saved via DPAPI):" -Output warn
                                try{
                                    $secInput = Read-Host -AsSecureString
                                    $plainTest = [System.Net.NetworkCredential]::new("", $secInput).Password
                                    if([string]::IsNullOrWhiteSpace($plainTest)){
                                        MsgFce "ERROR: RADIUS Shared Secret cannot be empty! Please try again." -Output error
                                        continue
                                    }
                                    $secInput | ConvertFrom-SecureString | Out-File $fileRad1 -ErrorAction Stop
                                    $rad1Pass = $plainTest
                                    MsgFce "INFO: Primary RADIUS Shared Secret successfully saved to '$($fileRad1)'"
                                } catch{
                                    MsgFce "ERROR: Failed to save Primary RADIUS secret: $($_.Exception.Message)" -Output error
                                    break
                                }
                            }
                        }
                        if([string]::IsNullOrWhiteSpace($rad1Pass)){ continue }
                        $stepData["sharedSecret"] = $rad1Pass
                    }

                    # Secondary RADIUS Secret
                    if(($stepData["enabledAux"] -eq "true" -or $stepData["enabledAux"] -eq $true -or $stepData["hostName_2"]) -and [string]::IsNullOrWhiteSpace($stepData["sharedSecret_2"])){
                        $fileRad2 = Join-Path $VAR.ScriptPath $VAR.SecCredRadius2
                        $rad2Pass = $null
                        if($RadiusSecret2){
                            $rad2Pass = $RadiusSecret2
                        } elseif(Test-Path $fileRad2 -PathType Leaf){
                            try{
                                $secStr = Get-Content $fileRad2 | ConvertTo-SecureString -ErrorAction Stop
                                $rad2Pass = [System.Net.NetworkCredential]::new("", $secStr).Password
                            } catch{
                                MsgFce "WARN: Secondary RADIUS credential file '$($fileRad2)' could not be decrypted. Re-prompting..." -Output warn
                                Remove-Item $fileRad2 -Force -ErrorAction SilentlyContinue
                            }
                        }

                        # Interactive prompt loop with mandatory non-empty check
                        while([string]::IsNullOrWhiteSpace($rad2Pass)){
                            if($isSilent){
                                MsgFce "ERROR: Silent execution failed for UAG '$($uag.Name)'! Secondary RADIUS Auth is enabled, but Secondary Shared Secret was not provided via '-RadiusSecret2' parameter and DPAPI file '$($fileRad2)' is missing or empty." -Output error
                                break
                            } else{
                                MsgFce "Enter Secondary RADIUS Shared Secret for UAG '$($uag.Name)' (it will be saved via DPAPI):" -Output warn
                                try{
                                    $secInput = Read-Host -AsSecureString
                                    $plainTest = [System.Net.NetworkCredential]::new("", $secInput).Password
                                    if([string]::IsNullOrWhiteSpace($plainTest)){
                                        MsgFce "ERROR: RADIUS Shared Secret cannot be empty! Please try again." -Output error
                                        continue
                                    }
                                    $secInput | ConvertFrom-SecureString | Out-File $fileRad2 -ErrorAction Stop
                                    $rad2Pass = $plainTest
                                    MsgFce "INFO: Secondary RADIUS Shared Secret successfully saved to '$($fileRad2)'"
                                } catch{
                                    MsgFce "ERROR: Failed to save Secondary RADIUS secret: $($_.Exception.Message)" -Output error
                                    break
                                }
                            }
                        }
                        if([string]::IsNullOrWhiteSpace($rad2Pass)){ continue }
                        $stepData["sharedSecret_2"] = $rad2Pass
                    }
                }


                # SAML IdP Metadata XML resolution
                if($step.ConfigKey -eq "samlSettings" -and $stepData.ContainsKey("idpMetadataPath")){
                    $xmlPath = $stepData["idpMetadataPath"]
                    if(-not [string]::IsNullOrWhiteSpace($xmlPath)){
                        if(Test-Path $xmlPath){
                            # Validate SAML Metadata Expiration (validUntil & embedded certs)
                            if(-not (Test-SamlMetadataExpiry -XmlPath $xmlPath -WarnDays $VAR.ExpiryWarnDays)){ throw "SAML Metadata validation failed due to expired components!" }

                            # Read XML file content as raw bytes and encode to Base64 string
                            $bytes = [System.IO.File]::ReadAllBytes($xmlPath)
                            $base64Xml = [System.Convert]::ToBase64String($bytes)
                            # Resolve Entity ID (defaults to 'SAML' if omitted)
                            $entityID = if(-not [string]::IsNullOrWhiteSpace($stepData["entityID"])){ $stepData["entityID"] } else{ "SAML" }

                            $stepData = [ordered]@{
                                idpURL                      = @{ trustedCertificates = @() }
                                metadata                    = $base64Xml
                                entityID                    = $entityID
                                encryptionCertAndKeyWrapper = $null
                                encryptionCertificateType   = $null
                                signingCertAndKeyWrapper    = $null
                                signingCertificateType      = $null
                            }
                        } else{
                            MsgFce "ERROR: SAML IdP Metadata XML file '$($xmlPath)' was not found!" -Output error
                            continue
                        }
                    } else{
                        continue
                    }
                }

                # Edge Service auto-binding SAML idpEntityID if SAML auth is enabled but idpEntityID is missing
                if($step.ConfigKey -eq "edgeService" -and $stepData["authMethods"] -like "*saml-auth*"){
                    if([string]::IsNullOrWhiteSpace($stepData["idpEntityID"])){
                        $samlCfg = $cfguag["samlSettings"]
                        $inferredEntityID = if($samlCfg -and -not [string]::IsNullOrWhiteSpace($samlCfg["entityID"])){ $samlCfg["entityID"] } else { "SAML" }
                        $stepData["idpEntityID"] = $inferredEntityID
                        MsgFce "INFO: Edge Service 'idpEntityID' was omitted. Automatically linked to '$($inferredEntityID)'" -NoTimeStamp
                    }
                }

               # Admin and Monitoring Users handling (GET to check, POST for new users, PUT for existing)
                if($step.ConfigKey -eq "adminUsers"){
                    # Convert hashtable or array to user collection
                    $usersList = if($configData -is [hashtable]){ $configData.Values } elseif($configData -is [array]){ $configData } else { @($configData) }
                    # Fetch existing users from UAG to determine HTTP verb (POST vs PUT)
                    $existingUsers = $null
                    try{
                        $existingUsers = Invoke-RestMethod -Method Get -Uri $uri -Headers $uagAuthHeader -ContentType "application/json" -ErrorAction Stop
                    } catch{
                        MsgFce "WARN: Unable to query existing admin users on '$($uag.Name)': $($_.Exception.Message)" -Output warn
                    }

                    # Safely extract array of user objects from the 'adminUsersList' wrapper property
                    $existingNames = @()
                    if($existingUsers){
                        $rawList = if($existingUsers.adminUsersList){ 
                            $existingUsers.adminUsersList 
                        } elseif($existingUsers.adminUsers){ 
                            $existingUsers.adminUsers 
                        } elseif($existingUsers -is [array]){ 
                            $existingUsers 
                        } else { 
                            @($existingUsers) 
                        }
                        $existingNames = $rawList | ForEach-Object { $_.name }
                    }

                    foreach($userDef in $usersList){
                        if([string]::IsNullOrWhiteSpace($userDef["name"])){ continue }

                        # Check password strength before calling REST API
                        if(-not (Test-UAGPasswordStrength -Password $userDef["password"] -Username $userDef["name"])){
                            MsgFce "WARN: Skipping API execution for user '$($userDef['name'])' due to password policy violation." -Output warn
                            continue
                        }

                        # Build user JSON payload matching UAG REST API specification
                        $userPayload = [ordered]@{
                            name                              = $userDef["name"]
                            password                          = $userDef["password"]
                            enabled                           = if($userDef.ContainsKey("enabled")){ [bool]$userDef["enabled"] } else { $true }
                            roles                             = if($userDef["roles"]){ @($userDef["roles"]) } else { @("ROLE_MONITORING") }
                            userType                          = if($userDef["userType"]){ $userDef["userType"] } else { "INTERNAL" }
                            adminMonitoringPasswordPreExpired = if($userDef.ContainsKey("adminMonitoringPasswordPreExpired")){ [bool]$userDef["adminMonitoringPasswordPreExpired"] } else { $false }
                        }

                        # Convert to JSON and enforce array formatting for "roles" in PowerShell 5.1
                        $userJson = ConvertTo-Json -InputObject $userPayload -Depth 5 -Compress
                        $userJson = $userJson -replace '"roles"\s*:\s*"([^"]+)"', '"roles":["$1"]'
                        # Determine HTTP method based on existing username match
                        $userExists = $existingNames -contains $userDef["name"]
                        $httpMethod = if($userExists){ "Put" } else { "Post" }

                        MsgFce "INFO: $($httpMethod.ToUpper()) user '$($userDef['name'])' (Role: $($userPayload.roles -join ',')) on UAG '$($uag.Name)'..."
                        for($attempt=1; $attempt -le $VAR.ApiMaxRetries; $attempt++){
                            try{
                                $null = Invoke-RestMethod -Method $httpMethod -Uri $uri -Body $userJson -ContentType "application/json" -Headers $uagAuthHeader
                                MsgFce "SUCCESS: User '$($userDef['name'])' successfully applied via API" -Output success
                                break
                            } catch{
                                if($attempt -lt $VAR.ApiMaxRetries){
                                    MsgFce "WARN: User '$($userDef['name'])' API attempt $attempt/$($VAR.ApiMaxRetries) failed ($($_.Exception.Message)). Retrying in $($VAR.ApiRetryDelay)s..." -Output warn
                                    Start-Sleep -Seconds $VAR.ApiRetryDelay
                                } else{
                                    MsgFce "ERROR: User '$($userDef['name'])' API failed after $($VAR.ApiMaxRetries) attempts! Error: $($_.Exception.Message)" -Output error
                                    if($VAR.DEBUG){
                                        $apiErrDetail = Get-RestErrorResponse -ErrorRecord $_
                                        if($apiErrDetail){ MsgFce "DEBUG [UAG API Error Details]: $($apiErrDetail)" -Output note }
                                    }
                                }
                            }
                        }
                    }
                    if($VAR.ApiStepDelay -gt 0){ Start-Sleep -Seconds $VAR.ApiStepDelay }
                    continue # Skip standard PUT execution below for "adminUsers" step
                }


                # API JSON Body
                $json = ConvertTo-Json -InputObject $stepData -Depth 10 -Compress

                if($VAR.DEBUG){
                    MsgFce "DEBUG [PUT URI]: $($uri)" -Output note
                    # Mask both RADIUS secrets in debug output
                    $jsonDebug = $json
                    if($stepData["sharedSecret"] -or $stepData["sharedSecret_2"]){
                        $dbg = @{}
                        foreach ($k in $stepData.Keys) { $dbg[$k] = $stepData[$k] }
                        if($dbg["sharedSecret"]){ $dbg["sharedSecret"] = "***" }
                        if($dbg["sharedSecret_2"]){ $dbg["sharedSecret_2"] = "***" }
                        $jsonDebug = ConvertTo-Json -InputObject $dbg -Compress
                    }
                    MsgFce "DEBUG [JSON Body]: $($jsonDebug)" -Output note
                }

                MsgFce "INFO: Configuring UAG $($step.Name)..."
                for($attempt=1; $attempt -le $VAR.ApiMaxRetries; $attempt++){
                    try{
                        $null = Invoke-RestMethod -Method Put -Uri $uri -Body $json -ContentType "application/json" -Headers $uagAuthHeader
                        MsgFce "SUCCESS: $($step.Name) via API successfully applied" -Output success
                        break
                    } catch{
                        if($attempt -lt $VAR.ApiMaxRetries){
                            MsgFce "WARN: $($step.Name) attempt $attempt/$($VAR.ApiMaxRetries) failed ($($_.Exception.Message)). Retrying in $($VAR.ApiRetryDelay)s..." -Output warn
                            Start-Sleep -Seconds $VAR.ApiRetryDelay
                        } else{
                            MsgFce "ERROR: $($step.Name) via API failed after $($VAR.ApiMaxRetries) attempts! Error: $($_.Exception.Message)" -Output error
                            if($VAR.DEBUG){
                                $apiErrDetail = Get-RestErrorResponse -ErrorRecord $_
                                if($apiErrDetail){ MsgFce "DEBUG [UAG API Error Details]: $($apiErrDetail)" -Output note }
                            }
                        }
                    }
                }

                # Short delay between API steps
                if($VAR.ApiStepDelay -gt 0){ Start-Sleep -Seconds $VAR.ApiStepDelay }
            }
        }

        # UAG Certificate upload
        if($doCert -and $certRequests){
            foreach($req in $certRequests){
                $uri = "$($uribase)$($req.Endpoint)"
                $json = ConvertTo-Json -InputObject $req.Data -Depth 3 -Compress
                if($VAR.DEBUG){
                    MsgFce "DEBUG [PUT URI]: $uri" -Output note
                    if($req.Data["pfxKeystore"]){ 
                        $debugHash = [ordered]@{
                            pfxKeystore = "...[BASE64DATA]..."
                            password    = "***"
                        }
                        if($req.Data["alias"]){ $debugHash["alias"] = $req.Data["alias"] }
                        $jsonDebug = ConvertTo-Json -InputObject $debugHash -Compress
                    } elseif($req.Data["certChainPem"]){
                        # Shorten/redact PEM data for debug output
                        $debugHash = [ordered]@{
                            certChainPem  = "...[PEM CERTIFICATE CHAIN]..."
                            privateKeyPem = "...[PEM PRIVATE KEY]..."
                        }
                        $jsonDebug = ConvertTo-Json -InputObject $debugHash -Compress
                    } else { 
                        $jsonDebug = $json 
                    }
                    MsgFce "DEBUG [JSON Body]: $jsonDebug" -Output note
                }

                MsgFce "INFO: Uploading '$($mSelCert)' certificate (Entity: $($req.Entity)) to UAG '$($uag.Name)'..."
                for($attempt=1; $attempt -le $VAR.ApiMaxRetries; $attempt++){
                    try{
                        $null = Invoke-RestMethod -Method Put -Uri $uri -Body $json -ContentType "application/json" -Headers $uagAuthHeader
                        MsgFce "SUCCESS: The certificate '$($mSelCert)' [$($req.Entity)] was successfully applied to UAG '$($uag.Name)'" -Output success
                        break
                    } catch{
                        if($attempt -lt $VAR.ApiMaxRetries){
                            MsgFce "WARN: Uploading certificate attempt $attempt/$($VAR.ApiMaxRetries) failed ($($_.Exception.Message)). Retrying in $($VAR.ApiRetryDelay)s..." -Output warn
                            Start-Sleep -Seconds $VAR.ApiRetryDelay
                        } else{
                            MsgFce "ERROR: Applying certificate [$($req.Entity)] to UAG '$($uag.Name)' failed after $($VAR.ApiMaxRetries) attempts! Error: $($_.Exception.Message)" -Output error
                            if($VAR.DEBUG){
                                $apiErrDetail = Get-RestErrorResponse -ErrorRecord $_
                                if($apiErrDetail){ MsgFce "DEBUG [UAG API Error Details]: $apiErrDetail" -Output note }
                                MsgFce "DEBUG [Exception StackTrace]: $($_.Exception.ToString())" -Output note
                            }
                        }
                    }
                }

                # Short delay between certificate API steps
                if($VAR.ApiStepDelay -gt 0){ Start-Sleep -Seconds $VAR.ApiStepDelay }
            }
        }
    }
} Catch {
    # Error Message handling
    MsgFce $_.Exception.Message -Output error
} finally {
    # --- Cleanup of Sensitive Data ---
    $passwSec = $null
    $rad1Pass = $null
    $rad2Pass = $null
    $certRequests = $null
    [GC]::Collect()

    # --- Log Maintenance ---
    if($shouldLog -and $VAR.LogArchiveFiles -gt 0){
        $LogFiles = Get-ChildItem -Path $LogDir -Filter "UAG_API_Manage_*.txt" -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }
        if($LogFiles.Count -gt $VAR.LogArchiveFiles){
            MsgFce "INFO: Log archive limit exceeded ($($LogFiles.Count)/$($VAR.LogArchiveFiles)) => Deleting oldest log files" -LinesBefore 1
            $LogFiles | Sort-Object LastWriteTime | Select-Object -First ($LogFiles.Count-$VAR.LogArchiveFiles) | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    # --- End Message ---
    MsgFce "***** End of the script '$($VAR.ScriptName)' *****" -Output note -LinesBefore 1 -LinesAfter 1

    # --- Stop Transcript ---
    if($Host.Name -match "ConsoleHost" -and $shouldLog){ Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
}

<#
.SYNOPSIS
   Automated configuration of Omnissa Unified Access Gateway (UAG) via REST API.

.DESCRIPTION
   Configures system settings, Horizon Edge services, RADIUS, SAML, SSL certificates, Syslog and local users
   on target Omnissa UAG appliances via REST API using DPAPI-secured credentials.

.LINK
   https://github.com/jfacz/UAG-Automation

.NOTES
    Version:        2610.0
    Author:         Jan Fara
    Creation Date:  2026-08-28
    Last Update:    2026-10-31

   [v2610.0 - 20261031] New separated file 'fce_UAG_Automation.ps1' with shared functions
                        New optional parameter -AdminPassword (SecureString): UAG admin password supplied by the caller (e.g. UAG deploy script) - used for the run
                        New optional switch -ValidateOnly: checks configuration, certificate, referenced files and secrets WITHOUT connecting to UAG
                        New optional parameter -ExpectedIP: warns when the inventory IP of the target UAG differs from the expected (management) IP
                        Local user password can be stored via DPAPI instead of plain text in cfg (password = "")
                        Configuration of UAG is aborted when a prerequisite is missing (RADIUS secret, SAML metadata, CA file)
                        Bug fixes and stability improvements
   [v2609.0 - 20260916] Added support for silent execution from UAG deploy script (with Transcript logging)
                        Added support for SAML and RADIUS authentication with storing shared secrets via DPAPI
                        Added support for local user accounts creation/updates via REST API
                        Bug fixes and stability improvements
   [v2608.0 - 20260828] Rewrote the previous simpler version of the script for UAG upload PEM certificate
                        UAG configuration in separate file
                        Added support for upload PFX certificate to UAG
                        Added secret storing UAG Admin passwords via DPAPI

.EXAMPLE
    # Execute interactive configuration menu
    .\UAG_Config.ps1

.EXAMPLE
    # Execute automated silent configuration with static certificate defined in cfg_UAG.ps1
    .\UAG_Config.ps1 -Mode CfgConfigAndCert -TargetUAG "VDI-UAGE01" -CertName "vdi.company.com [PFX]" -CertPfxPassword "SecretPass123"

.EXAMPLE
    # Upload PEM/PFX certificate via CLI parameters
    .\UAG_Config.ps1 -Mode CfgCertOnly -TargetUAG ALL -CertPem "C:\Cert\fullchain.pem" -CertKeyPem "C:\Cert\privkey.pem"
    .\UAG_Config.ps1 -Mode CfgCertOnly -TargetUAG "VDI-UAGE01","VDI-UAGE02" -CertPfxPath "C:\Cert\vdi.pfx" -CertPfxPassword "SecretPass123"

.EXAMPLE
    # Validation only (no connection to UAG, no changes): configuration, certificate, referenced files and secrets
    .\UAG_Config.ps1 -Mode CfgConfigAndCert -TargetUAG "VDI-UAGE01" -CertName "vdi.company.com [PEM]" -ValidateOnly
#>

#Requires -Version 5.1

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
    [string[]] $TargetUAG,

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
    [string] $RadiusSecret2,

    # --- UAG Admin Credentials / Validation ---
    [Parameter(Mandatory=$false, HelpMessage="UAG admin password (SecureString) supplied by the caller; used for this run and saved via DPAPI. Only for a single target UAG")]
    [System.Security.SecureString] $AdminPassword,

    [Parameter(Mandatory=$false, HelpMessage="Validate configuration, certificate, files and secrets only - UAG is not contacted and nothing is changed")]
    [switch] $ValidateOnly,

    [Parameter(Mandatory=$false, HelpMessage="Expected IP (management) of the single target UAG; a warning is shown if the inventory IP differs")]
    [string] $ExpectedIP
)

# --- Loading Required scripts ---
$psArr = @("fce_UAG_Automation.ps1")
foreach($ps in $psArr){
    $psPath = Join-Path $PSScriptRoot $ps
    if(-not (Test-Path $psPath -PathType Leaf)){ throw "ERROR: Unable to load required script. File '$($psPath)' not found!" }
    . $psPath
}
if(-not $FceVersion -or [version]$FceVersion -lt [version]"2610.0"){ throw "ERROR: Required script 'fce_UAG_Automation.ps1' is too old (version '$($FceVersion)', required 2610.0 or newer)!" }

# ==============================================================================
# SETTINGS
# ==============================================================================
$VAR = @{
 # Script Name
  ScriptName = "UAG Config"
 # Script Path ($PSScriptRoot for current folder)
  ScriptPath = $PSScriptRoot

 # --- API NETWORK & RETRY SETTINGS ---
  UagApiPort = 9443
 # Timeout in seconds to wait/check if UAG API is ready (the first startup of a newly deployed system should take less than 2 minutes)
  UagWaitTimeout = 120
  ApiMaxRetries  = 5   # Maximum attempts per API call on network error / HTTP 5xx (HTTP 4xx is never retried)
  ApiRetryDelay  = 5   # Delay in seconds between failed retry attempts
  ApiStepDelay   = 1   # Settling delay in seconds between steps for UAG daemons

 # --- SECURITY ---
  ExpiryWarnDays = 30  # Number of days to warn before upcoming expiration (SSL cert and SAML metadata)
 # Credential files for UAG, local users, RADIUS and PFX certificates (stored via DPAPI per computer and user)
  SecCredUAG    = "sec_uag_{0}_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  SecCredUser   = "sec_user_{0}_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  SecCredRadius = "sec_radius_{0}_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  SecCredPfx    = "sec_pfx_{0}_$($env:COMPUTERNAME)_$($env:USERNAME).txt"

 # --- LOG SETTINGS ---
  LogOnlyIfSilent = $true
  LogDir          = "Logs"
  LogFileName     = "UAG_Config_{0:yyyyMMdd_HHmmss}.txt"
  LogArchiveFiles = 10

  # Debug mode (for more verbose output)
  DEBUG = $false
}

# ==============================================================================

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
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
            $validCount = 0
            $seenThumbprints = @{} # Dictionary to track unique certificates
            foreach($node in $certNodes){
                $cleanCert = $node.InnerText -replace '\s',''
                if(-not [string]::IsNullOrWhiteSpace($cleanCert)){
                    $certBytes = [System.Convert]::FromBase64String($cleanCert)
                    $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$certBytes)
                    # Process each unique certificate only once
                    if(-not $seenThumbprints.ContainsKey($certObj.Thumbprint)){
                        $seenThumbprints[$certObj.Thumbprint] = $true
                        if(($now -ge $certObj.NotBefore) -and ($now -le $certObj.NotAfter)){
                            $validCount++
                            $daysLeft = ($certObj.NotAfter - $now).Days
                            if($daysLeft -le $WarnDays){
                                MsgFce "WARN: SAML Embedded Cert '$($certObj.Subject)' expires in $($daysLeft) days ($($certObj.NotAfter.ToString('yyyy-MM-dd')))" -Output warn -NoTimeStamp
                            } else{
                                MsgFce "INFO: SAML Embedded Cert '$($certObj.Subject)' is valid ($($daysLeft) days remaining, expires: $($certObj.NotAfter.ToString('yyyy-MM-dd')))" -NoTimeStamp
                            }
                        } else{
                            MsgFce "WARN: SAML Embedded Cert '$($certObj.Subject)' is not valid now (valid $($certObj.NotBefore.ToString('yyyy-MM-dd')) - $($certObj.NotAfter.ToString('yyyy-MM-dd'))) => ignored" -Output warn -NoTimeStamp
                        }
                    }
                }
            }
            if($validCount -eq 0){
                MsgFce "ERROR: SAML Metadata does not contain any currently valid X.509 certificate!" -Output error -NoTimeStamp
                return $false
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
        if(-not (Test-CertificateExpiry -CertObject $pemCertObj -CertName $certPemPath -WarnDays $VAR.ExpiryWarnDays)){ throw "Certificate expiration check failed!" }

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

        # PFX Password resolution (Parameter -> DPAPI File -> Interactive Prompt saved via DPAPI)
        # It is resolved also in validation-only mode => the password is asked BEFORE the deployment and the real run then needs no prompt
        $pfxSecName = [System.IO.Path]::GetFileNameWithoutExtension($pfxPath) -replace '[\\/:*?"<>| ]', '_'
        $pfxSecFile = Join-Path $VAR.ScriptPath ($VAR.SecCredPfx -f $pfxSecName)
        $passPlain = Get-DpapiSecret -FilePath $pfxSecFile `
            -Description "password for PFX certificate '$($pfxPath)'" `
            -ParamValue $CertPfxPassword `
            -Validate { param($p) try{ $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $pfxPath, $p; $true } catch{ MsgFce "WARN: PFX '$($pfxPath)' cannot be opened with this password: $($_.Exception.Message)" -Output warn -NoTimeStamp; $false } } `
            -AsPlainText
        if(-not $passPlain){ throw "ERROR: Password for PFX certificate '$($pfxPath)' is not available!" }

        # Local validation: Password, Private Key & Expiration
        try{
            $pfxCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $pfxPath, $passPlain
            if(-not $pfxCertObj.HasPrivateKey){ throw "PFX file does not contain a private key!" }
            if(-not (Test-CertificateExpiry -CertObject $pfxCertObj -CertName $pfxPath -WarnDays $VAR.ExpiryWarnDays)){ throw "Certificate expiration check failed!" }
        } catch{
            $passPlain = $null
            throw "Failed to open or validate PFX certificate! Error: $($_.Exception.Message) (wrong password? delete the saved password file '$($pfxSecFile)' and run again)"
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
            Entity     = $entity
            Endpoint   = "$baseEndpoint/$entity"
            Data       = $bodyData
        }
    }
    return $requests
}

# Reads a PEM file (or binary DER .cer/.crt), strips BOM, and extracts all X.509 certificate blocks as PEM
Function Get-PemContentFromFile {
    param (
        [Parameter(Mandatory=$true)]
        [string] $FilePath
    )

    if(-not (Test-Path -Path $FilePath -PathType Leaf)){ return $null }

    $resolvedPath = (Resolve-Path $FilePath).Path
    $rawText = [System.IO.File]::ReadAllText($resolvedPath).Replace(([char]0xFEFF).ToString(), "")
    $certMatches = [regex]::Matches($rawText, '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----')
    if($certMatches.Count -gt 0){
        return ($certMatches | ForEach-Object { $_.Value }) -join "`n"
    }

    # No PEM header => try binary DER certificate and convert it to PEM
    try{
        $derCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[System.IO.File]::ReadAllBytes($resolvedPath))
        $b64 = [System.Convert]::ToBase64String($derCert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks) -replace "`r`n", "`n"
        return "-----BEGIN CERTIFICATE-----`n$($b64)`n-----END CERTIFICATE-----"
    } catch{
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
    # Check for forbidden/problematic characters in UAG API (spaces, '+', '=' and quotes)
    if($Password -match '[\s+=''"]'){
        MsgFce "ERROR: Password for user '$($Username)' contains invalid characters (do not use +, spaces, =, or quotes)!" -Output error
        return $false
    }
    # Validate all 4 required character classes for UAG REST API (allowed special characters exclude the forbidden ones above)
    $hasUpper   = $Password -match '[A-Z]'
    $hasLower   = $Password -match '[a-z]'
    $hasDigit   = $Password -match '\d'
    $hasSpecial = $Password -match '[!@#$%^&*()_\-\[\]{};:\\|,.<>/?]'

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

# Helper function: Masks sensitive properties in JSON payloads for safe debug logging
Function Format-UagDebugJson {
    param ([string] $Body)

    if([string]::IsNullOrWhiteSpace($Body)){ return $Body }

    try{
        $obj = $Body | ConvertFrom-Json -ErrorAction Stop
        # 1. Mask top-level properties
        $masks = @{
            sharedSecret = "***"; sharedSecret_2 = "***"; password = "***"
            metadata = "...[BASE64 XML METADATA]..."; pfxKeystore = "...[BASE64DATA]..."
            certChainPem = "...[PEM CERTIFICATE CHAIN]..."; privateKeyPem = "...[PEM PRIVATE KEY]..."
        }
        $masks.Keys | ForEach-Object {
            if ($obj.PSObject.Properties[$_] -and $null -ne $obj.$_) { 
                $obj.$_ = $masks[$_] 
            }
        }
        # 2. Mask nested certificates in Horizon Edge configuration
        if ($obj.PSObject.Properties['trustedCertificates'] -and $null -ne $obj.trustedCertificates) {
            foreach ($cert in $obj.trustedCertificates) {
                if ($cert.PSObject.Properties['data'] -and $null -ne $cert.data) {
                    $cert.data = "...[PEM TRUSTED CERTIFICATE]..."
                }
            }
        }
        return ($obj | ConvertTo-Json -Depth 10 -Compress)
    } catch {
        # Fallback if Body is not valid JSON
        return $Body
    }
}

# Calls UAG REST API. Retries only on network errors / HTTP 5xx / 408 / 429, never on HTTP 4xx (esp. 401 = UAG admin lockout policy)
# Returns hashtable: Success, Response, StatusCode, ErrorText
Function Invoke-UagApi {
    param (
        [Parameter(Mandatory=$true)] [ValidateSet("Get", "Put", "Post")] [string] $Method,
        [Parameter(Mandatory=$true)] [string] $Uri,
        [Parameter(Mandatory=$true)] [hashtable] $Headers,
        [string] $Body,
        [string] $Label = "API call",
        [int] $MaxRetries = $VAR.ApiMaxRetries,
        [switch] $Quiet
    )

    $MaxRetries = [Math]::Max(1, $MaxRetries)
    $result = @{ Success = $false; Response = $null; StatusCode = $null; ErrorText = $null }
    $irmParams = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = "Stop" }
    if($PSBoundParameters.ContainsKey("Body")){
        # UTF-8 encoded body, regardless of PowerShell version
        $irmParams["Body"] = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $irmParams["ContentType"] = "application/json"
    }
    
    if($VAR.DEBUG){
        MsgFce "DEBUG [Label]: $Label" -Output note
        MsgFce "DEBUG [URI]: $($irmParams.Uri)" -Output note
        MsgFce "DEBUG [Method]: $Method" -Output note
        MsgFce "DEBUG [JSON Body]: $(Format-UagDebugJson -Body $Body)" -Output note
    }

    for($attempt=1; $attempt -le $MaxRetries; $attempt++){
        try{
            $result.Response = Invoke-RestMethod @irmParams
            $result.Success = $true
            return $result
        } catch{
            $err = $_
            $result.StatusCode = $null
            if($err.Exception.Response){ try{ $result.StatusCode = [int]$err.Exception.Response.StatusCode } catch{ } }
            $apiErr = Get-RestErrorResponse -ErrorRecord $err
            $result.ErrorText = $err.Exception.Message
            if($apiErr){
                $apiErr = ($apiErr -replace '\s+', ' ').Trim()
                if($apiErr.Length -gt 500){ $apiErr = $apiErr.Substring(0, 500) + "..." }
                $result.ErrorText += " | API response: $($apiErr)"
            }

            # Wrong credentials => no retry (failed logins count towards UAG admin lockout) and stop processing of this UAG
            if($result.StatusCode -eq 401){ $script:UagAuthFailed = $true; break }

            $retryable = (-not $result.StatusCode) -or ($result.StatusCode -ge 500) -or ($result.StatusCode -in @(408, 429))
            if($retryable -and $attempt -lt $MaxRetries){
                if(-not $Quiet){ MsgFce "WARN: $($Label) attempt $attempt/$($MaxRetries) failed ($($err.Exception.Message)). Retrying in $($VAR.ApiRetryDelay)s..." -Output warn }
                Start-Sleep -Seconds $VAR.ApiRetryDelay
                continue
            }
            break
        }
    }

    if(-not $Quiet){
        MsgFce "ERROR: $($Label) via API failed after $($attempt) attempt(s)! Error: $($result.ErrorText)" -Output error
    }
    return $result
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------
$script:HadError = $false        # Any error occurred => exit code 1
$script:UagAuthFailed = $false   # UAG rejected credentials (HTTP 401) => stop processing of the UAG
$ValidateOnly = [bool] $ValidateOnly   # validation only: UAG is not contacted, nothing is changed
$isSilent = [bool]($Mode -or $TargetUAG -or $CertPem -or $CertPfxPath -or $ValidateOnly)
# Prompts (Read-Host / menu) are possible only in a user session started without -NonInteractive (scheduled task / child process = no prompts)
$isInteractive = Test-IsInteractive
$shouldLog = (-not $VAR.LogOnlyIfSilent) -or $isSilent
$LogDir  = Join-Path $VAR.ScriptPath $VAR.LogDir
$LogFile = (Join-Path $LogDir $VAR.LogFileName) -f (Get-Date)
# ScriptName update
$VAR.ScriptName += if($ValidateOnly){ " [VALIDATION ONLY]" } elseif($Mode){ " [MODE $($Mode)]"} elseif($isInteractive){" [INTERACTIVE MODE]" } else {}

# Ignore invalid SSL certificates during API calls & set TLS 1.2
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
# PowerShell 7+ ignores the callback above
if($PSVersionTable.PSVersion.Major -ge 6){ $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true }

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
$TranscriptOn = $false
if($shouldLog){
    $TranscriptOn = Start-ScriptTranscript -LogDir $LogDir -LogFile $LogFile
    if(-not $TranscriptOn){ $shouldLog = $false }
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
Try{
    if(-not $isSilent -and $isInteractive){ Clear-Host }
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

    # UAG inventory must exist and not be empty
    if(-not $UAG){
        MsgFce "ERROR: UAG inventory '`$UAG' is missing or empty in '$($UagCfg)'!" -Output error
        return
    }

    # --- Execution Mode Selection ---
    if($Mode){
        $doConfig = $Mode -in @("CfgConfigAndCert", "CfgConfigOnly")
        $doCert   = $Mode -in @("CfgConfigAndCert", "CfgCertOnly")
    } else{
        if(-not $isInteractive){ throw "ERROR: Non-interactive execution failed! '-Mode' parameter was not specified." }
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
        # "ALL", one name or a list of names (with 'powershell -File' a list arrives as one comma separated string => split)
        $targetNames = @($TargetUAG -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if($targetNames -contains "ALL"){
            $selUAG = $UAG
        } else{
            $missing = @($targetNames | Where-Object { $_ -notin $UAG.Name })
            if($missing){ throw "ERROR: Target UAG '$($missing -join "', '")' not found in inventory!" }
            $selUAG = @($UAG | Where-Object { $_.Name -in $targetNames })
        }
    } elseif($UAG.Count -eq 1){
        # Auto-select if only 1 UAG appliance is defined in $UAG inventory
        $selUAG = $UAG
        MsgFce "INFO: Single UAG appliance detected in inventory. Automatically selected: '$($selUAG[0].Name)'" -NoTimeStamp
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

    # --- UAG admin password / expected IP can be used only for a single UAG ---
    if(($AdminPassword -or $ExpectedIP) -and @($selUAG).Count -ne 1){ throw "ERROR: Parameters '-AdminPassword' and '-ExpectedIP' can be used only with a single target UAG (selected: $(@($selUAG).Count))!" }

    # --- SSL Certificate Selection (Dynamic CLI > -CertName > 'CertName' in UAG inventory > single/menu from $CERTS) ---
    # Result: $certPlan = UAG name -> @{ Name = certificate name; Requests = API requests }
    $certPlan = @{}
    if($doCert){
        # Option A: Dynamic CLI certificate upload (e.g. Let's Encrypt / ACME renewal hook) - the same certificate for all selected UAGs
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
            $dynamicRequests = @(Get-UagCertApiData -CertDef $dynamicCertDef)
            foreach($sel in $selUAG){ $certPlan[$sel.Name] = @{ Name = $mSelCert; Requests = $dynamicRequests } }
        }
        # Option B: Static configuration from cfg_UAG.ps1 ($CERTS hashtable)
        else{
            if($null -eq $CERTS -or $CERTS.Count -eq 0){ throw "ERROR: No certificate defined in '`$CERTS' hashtable!" }

            # Certificate name per UAG: '-CertName' parameter (all selected UAGs) > 'CertName' of the UAG in the inventory
            $certNames = @{}
            foreach($sel in $selUAG){
                $n = if($CertName){ $CertName } elseif(-not [string]::IsNullOrWhiteSpace($sel.CertName)){ $sel.CertName } else { $null }
                if($n){ $certNames[$sel.Name] = $n }
            }
            if($CertName){ MsgFce "Certificate set via parameter: '$($CertName)'" -NoTimeStamp }

            # UAGs without an assigned certificate: single certificate in $CERTS / interactive menu
            $unassigned = @($selUAG | Where-Object { -not $certNames.ContainsKey($_.Name) })
            if($unassigned.Count -gt 0){
                if($CERTS.Count -eq 1){
                    # Auto-select if only 1 certificate is defined in $CERTS hashtable
                    $mSelCert = $CERTS.Keys | Select-Object -First 1
                    MsgFce "INFO: Single certificate detected in `$CERTS. Automatically selected: '$($mSelCert)'" -NoTimeStamp
                } elseif(-not $isInteractive){
                    # Safety Fail-Safe: an unattended run (scheduled task / child process) cannot show a menu => explicit certificate is required
                    throw "ERROR: Non-interactive execution failed! Multiple certificates found in `$CERTS, but no certificate is assigned to UAG '$($unassigned[0].Name)' (add 'CertName' to the UAG in the inventory or use the '-CertName' parameter)."
                } else{
                    $mTitle = "Select SSL Certificate to apply to UAG $($unassigned.Name -join ', ')"
                    $mOpts = @("Exit") + ($CERTS.Keys | Sort-Object)
                    $mSelCert = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
                    if($mSelCert -like "Exit"){
                        MsgFce "WARN: Terminated by user (exit)" -Output warn -NoTimeStamp
                        return
                    } else{
                        MsgFce "Selected certificate: '$($mSelCert)'" -NoTimeStamp
                    }
                }
                foreach($sel in $unassigned){ $certNames[$sel.Name] = $mSelCert }
            }

            # Prepare API requests (each certificate is validated and prepared once)
            $requestsCache = @{}
            foreach($sel in $selUAG){
                $n = $certNames[$sel.Name]
                if(-not $CERTS.ContainsKey($n)){ throw "ERROR: Certificate '$($n)' of UAG '$($sel.Name)' was not found in `$CERTS hashtable!" }
                if(-not $requestsCache.ContainsKey($n)){
                    Confirm-NoPlaceholders -Data $CERTS[$n] -Path "`$CERTS['$($n)']" -Context "certificate definition '$($n)'"
                    $requestsCache[$n] = @(Get-UagCertApiData -CertDef $CERTS[$n])
                }
                $certPlan[$sel.Name] = @{ Name = $n; Requests = $requestsCache[$n] }
            }
        }
    }

    # --- Summary of execution parameters (Always logged) ---
    MsgFce "Summary of execution parameters:" -Output verbose -NoTimeStamp -LinesBefore 1
    MsgFce "  - Script Name:    $($VAR.ScriptName)" -NoTimeStamp
    MsgFce "  - Config File:    $($UagCfg)" -NoTimeStamp
    MsgFce "  - Execution Mode: $(if($Mode){ $Mode } else { $mMode })" -NoTimeStamp
    MsgFce "  - Target UAG(s):  $($selUAG.Name -join ', ')" -NoTimeStamp
    if($ExpectedIP){ MsgFce "  - Expected IP:    $($ExpectedIP)" -NoTimeStamp }
    MsgFce "  - Admin Pwd Set:  $($null -ne $AdminPassword)" -NoTimeStamp
    if($doCert){ foreach($sel in $selUAG){ MsgFce "  - SSL Cert ($($sel.Name)): $($certPlan[$sel.Name].Name)" -NoTimeStamp } }

    # --- Interactive Safety Confirmation Prompt ---
    if(-not $isSilent){
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
        @{ Name = "Users settings";      ConfigKey = "adminUsers";     Endpoint = "/rest/v1/config/adminusers" }
        @{ Name = "Syslog settings";     ConfigKey = "syslogSettings"; Endpoint = "/rest/v1/config/syslog" }
    )

    # --- Process each selected UAG (every UAG in isolation - an error on one UAG does not stop the others) ---
    foreach($uagNode in $selUAG){
        MsgFce "INFO: $(if($ValidateOnly){ 'Validation' } else { 'API configuration' }) of UAG '$($uagNode.Name)' (IP: $($uagNode.IP))..." -Output verbose -LinesBefore 1
        if($ExpectedIP -and $uagNode.IP -ne $ExpectedIP){
            MsgFce "WARN: Inventory IP of UAG '$($uagNode.Name)' is '$($uagNode.IP)', but the expected (management) IP is '$($ExpectedIP)'! The REST API (port $($VAR.UagApiPort)) is available on the management address." -Output warn
        }
        $script:UagAuthFailed = $false

        try{
            # Unfilled placeholders '<...>' in the inventory entry of this UAG
            Confirm-NoPlaceholders -Data $uagNode -Path "`$UAG['$($uagNode.Name)']" -Context "inventory of UAG '$($uagNode.Name)'"

            # Base API URI for UAG
            $uribase = "https://$($uagNode.IP):$($VAR.UagApiPort)"
            $passwSec = $null
            $uagAuthHeader = $null

            # DPAPI Authorization for UAG Admin
            $SecCredUAG = Join-Path $VAR.ScriptPath ($VAR.SecCredUAG -f ($uagNode.Name))

            if($ValidateOnly){
                # Validation only: UAG is not contacted and nothing is asked (the admin password of a newly deployed UAG is set by the deploy script) => only a check that the credentials will be available
                if(-not $AdminPassword -and -not (Test-Path $SecCredUAG -PathType Leaf) -and -not $isInteractive){
                    MsgFce "ERROR: Non-interactive execution would fail for UAG '$($uagNode.Name)'! Password file '$($SecCredUAG)' does not exist and '-AdminPassword' was not provided. Run the script interactively first (under the same account) to save credentials." -Output error
                }
                MsgFce "INFO: Validation only - UAG '$($uagNode.Name)' is not contacted"
            } else{
                if($AdminPassword){
                    # Password supplied by the caller (e.g. UAG deploy script) - used for this run and saved via DPAPI for the later (non-interactive) runs
                    $passwSec = $AdminPassword
                    try{
                        $AdminPassword | ConvertFrom-SecureString | Out-File $SecCredUAG -ErrorAction Stop
                        MsgFce "INFO: Password for UAG '$($uagNode.Name)' (supplied via parameter) was saved via DPAPI to '$($SecCredUAG)'"
                    } catch{
                        MsgFce "WARN: Password for UAG '$($uagNode.Name)' could not be saved via DPAPI ($($_.Exception.Message)) => used for this run only" -Output warn
                    }
                } else{
                    # DPAPI file -> interactive prompt (saved via DPAPI), with strength validation
                    $passwSec = Get-DpapiSecret -FilePath $SecCredUAG `
                        -Description "admin password for UAG '$($uagNode.Name)'" `
                        -Validate { param($p) $hadErrorBefore = $script:HadError; $pwdOk = Test-UAGPasswordStrength -Password $p -Username $uagNode.User; $script:HadError = $hadErrorBefore; $pwdOk }
                }
                if(-not $passwSec){
                    MsgFce "ERROR: Admin credentials for UAG '$($uagNode.Name)' are not available => skipping appliance!" -Output error
                    continue
                }

                # UAG Authorization header
                $uagCred = [System.Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f $uagNode.User,([System.Net.NetworkCredential]::new("",$passwSec).Password))))
                $uagAuthHeader = @{"Authorization" = "Basic $($uagCred)" }

                # Check/Wait for UAG API Port availability
                $timeout = $VAR.UagWaitTimeout
                MsgFce "INFO: Checking if UAG '$($uagNode.Name)' ($($uagNode.IP):$($VAR.UagApiPort)) is ready (up to $($timeout)s)..."
                $waitInterval = 5
                $portReady = $false

                while($timeout -gt 0){
                    try{
                        $tcp = New-Object System.Net.Sockets.TcpClient
                        $asyncConnect = $tcp.BeginConnect($uagNode.IP, $VAR.UagApiPort, $null, $null)
                        $waitSuccess = $asyncConnect.AsyncWaitHandle.WaitOne(1000, $false)
                        if($waitSuccess -and $tcp.Connected){
                            $tcp.Close()
                            $portReady = $true
                            break
                        }
                        $tcp.Close()
                    } catch { }

                    MsgFce "Waiting... UAG '$($uagNode.Name)' ($($uagNode.IP):$($VAR.UagApiPort)) is not ready yet. Next check in $($waitInterval)s (Timeout in $($timeout)s)." -Output note
                    Start-Sleep -Seconds $waitInterval
                    $timeout -= $waitInterval
                }

                if(-not $portReady) {
                    MsgFce "ERROR: Timeout waiting for UAG '$($uagNode.Name)' ($($uagNode.IP):$($VAR.UagApiPort)) to become ready. Skipping..." -Output error
                    continue
                }
                MsgFce "SUCCESS: UAG '$($uagNode.Name)' ($($uagNode.IP):$($VAR.UagApiPort)) is online and ready" -Output success
            }

            # UAG API Configuration
            if($doConfig){
                # Configuration Merging
                $cfguag = $UAG_CFG["ALL"].Clone()
                if($UAG_CFG.ContainsKey($uagNode.Name)){
                    MsgFce "INFO: Custom overrides found for UAG '$($uagNode.Name)'. Merging configurations..."
                    $cfguag = Merge-Hashtables -Base $cfguag -Override $UAG_CFG[$uagNode.Name]
                } else{
                    MsgFce "INFO: No overrides found for UAG '$($uagNode.Name)'. Deploying global (standard) configuration..."
                }

                # Unfilled placeholders '<...>' in the resulting (merged) configuration of this UAG
                Confirm-NoPlaceholders -Data $cfguag -Path "`$UAG_CFG['$($uagNode.Name)']" -Context "configuration of UAG '$($uagNode.Name)'"

                foreach($step in $API_Steps){
                    if($script:UagAuthFailed){ break }
                    $configData = $cfguag[$step.ConfigKey]
                    if($null -eq $configData -or $configData.Count -eq 0){ continue }

                    # Base URI for current API step
                    $uri = $uribase + $step.Endpoint

                    # Safe copy of configuration dictionary
                    $stepData = @{}
                    foreach ($k in $configData.Keys) { $stepData[$k] = $configData[$k] }

                    # Horizon Edge Service (View) Certificate Resolution
                    if($step.ConfigKey -eq "edgeService"){
                        # 1. Trusted CA Certificates (Array of PEM/DER files)
                        if($stepData.ContainsKey("trustedCertificates") -and $stepData["trustedCertificates"]){
                            $parsedCerts = @()
                            foreach($path in $stepData["trustedCertificates"]){
                                if(-not [string]::IsNullOrWhiteSpace($path)){
                                    # Validate CA Certificate Expiration
                                    try{
                                        $caCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
                                        if(-not (Test-CertificateExpiry -CertObject $caCertObj -CertName $path -WarnDays $VAR.ExpiryWarnDays)){ throw "Certificate expiration check failed!" }
                                    } catch{
                                        throw "ERROR: Failed to validate CA certificate file '$($path)'! $($_.Exception.Message) => configuration of UAG '$($uagNode.Name)' aborted!"
                                    }
                                    # Cert PEM Data
                                    $pemContent = Get-PemContentFromFile -FilePath $path
                                    if(-not $pemContent){ throw "ERROR: Trusted CA certificate file '$($path)' was not found => configuration of UAG '$($uagNode.Name)' aborted!" }
                                    $parsedCerts += @{
                                        name = [System.IO.Path]::GetFileName($path)
                                        data = $pemContent
                                    }
                                }
                            }
                            $stepData["trustedCertificates"] = $parsedCerts
                        }

                        # 2. Proxy Blast & Tunnel PEM Certificates (Single or Multi PEM file per property)
                        foreach($certProp in @("proxyBlastPemCert", "proxyTunnelPemCert")){
                            if($stepData.ContainsKey($certProp) -and -not [string]::IsNullOrWhiteSpace($stepData[$certProp])){
                                $path = $stepData[$certProp]
                                # Validate Proxy Certificate Expiration
                                try {
                                    $proxyCertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($path)
                                    if(-not (Test-CertificateExpiry -CertObject $proxyCertObj -CertName $path -WarnDays $VAR.ExpiryWarnDays)){ throw "Certificate expiration check failed!" }
                                } catch {
                                    throw "ERROR: Failed to validate certificate file '$($path)' for '$($certProp)'! $($_.Exception.Message) => configuration of UAG '$($uagNode.Name)' aborted!"
                                }
                                # Cert PEM Data
                                $pemContent = Get-PemContentFromFile -FilePath $path
                                if(-not $pemContent){ throw "ERROR: Certificate file '$($path)' for '$($certProp)' was not found => configuration of UAG '$($uagNode.Name)' aborted!" }
                                $stepData[$certProp] = $pemContent
                            }
                        }
                    }

                    # RADIUS Shared Secrets resolution (Parameter -> DPAPI File -> Interactive Prompt)
                    if($step.ConfigKey -eq "radiusSettings" -and ($stepData["enabled"] -eq $true -or $stepData["enabled"] -eq "true")){
                        # Primary RADIUS Secret
                        if([string]::IsNullOrWhiteSpace($stepData["sharedSecret"])){
                            # Clean per-appliance identifier derived strictly from appliance inventory name
                            $radId1 = "$($uagNode.Name)_primary"
                            $radIdClean1 = $radId1 -replace '[\\/:*?"<>| ]', '_'
                            $radFile1 = Join-Path $VAR.ScriptPath ($VAR.SecCredRadius -f $radIdClean1)
                            $rad1Pass = Get-DpapiSecret -FilePath $radFile1 `
                                -Description "Primary RADIUS Shared Secret for UAG '$($uagNode.Name)'" `
                                -ParamValue $RadiusSecret `
                                -AsPlainText
                            if(-not $rad1Pass){ throw "ERROR: RADIUS Auth is enabled, but Primary Shared Secret is not available => configuration of UAG '$($uagNode.Name)' aborted!" }
                            $stepData["sharedSecret"] = $rad1Pass
                        }

                        # Secondary RADIUS Secret
                        if(($stepData["enabledAux"] -eq "true" -or $stepData["enabledAux"] -eq $true -or $stepData["hostName_2"]) -and [string]::IsNullOrWhiteSpace($stepData["sharedSecret_2"])){
                            # Clean per-appliance identifier derived strictly from appliance inventory name
                            $radId2 = "$($uagNode.Name)_secondary"
                            $radIdClean2 = $radId2 -replace '[\\/:*?"<>| ]', '_'
                            $radFile2 = Join-Path $VAR.ScriptPath ($VAR.SecCredRadius -f $radIdClean2)
                            $rad2Pass = Get-DpapiSecret -FilePath $radFile2 `
                                -Description "Secondary RADIUS Shared Secret for UAG '$($uagNode.Name)'" `
                                -ParamValue $RadiusSecret2 `
                                -AsPlainText
                            if(-not $rad2Pass){ throw "ERROR: Secondary RADIUS is enabled, but Secondary Shared Secret is not available => configuration of UAG '$($uagNode.Name)' aborted!" }
                            $stepData["sharedSecret_2"] = $rad2Pass
                        }
                    }

                    # SAML IdP Metadata XML resolution
                    if($step.ConfigKey -eq "samlSettings" -and $stepData.ContainsKey("idpMetadataPath")){
                        $xmlPath = $stepData["idpMetadataPath"]
                        if(-not [string]::IsNullOrWhiteSpace($xmlPath)){
                            if(-not (Test-Path $xmlPath)){ throw "ERROR: SAML IdP Metadata XML file '$($xmlPath)' was not found => configuration of UAG '$($uagNode.Name)' aborted!" }

                            # Validate SAML Metadata Expiration (validUntil & embedded certs)
                            if(-not (Test-SamlMetadataExpiry -XmlPath $xmlPath -WarnDays $VAR.ExpiryWarnDays)){ throw "SAML Metadata validation failed due to expired components => configuration of UAG '$($uagNode.Name)' aborted!" }

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
                        # Fetch existing users from UAG to determine HTTP verb (POST vs PUT) - without it the step is skipped
                        $getUsers = if($ValidateOnly){ @{ Success = $true; Response = $null } } else { Invoke-UagApi -Method Get -Uri $uri -Headers $uagAuthHeader -Label "Query of existing admin users on UAG '$($uagNode.Name)'" }
                        if(-not $getUsers.Success){
                            MsgFce "ERROR: $($step.Name) skipped on UAG '$($uagNode.Name)' (existing users could not be queried)" -Output error
                            continue
                        }
                        $existingUsers = $getUsers.Response

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
                            if($script:UagAuthFailed){ break }

                            # Password resolution (cfg value -> DPAPI File -> Interactive Prompt). Empty 'password' in cfg = stored via DPAPI
                            $userPass = $userDef["password"]
                            if([string]::IsNullOrWhiteSpace($userPass)){
                                $fileUser = Join-Path $VAR.ScriptPath ($VAR.SecCredUser -f $userDef["name"])
                                $userPass = Get-DpapiSecret -FilePath $fileUser -Description "password for UAG local user '$($userDef['name'])'" -Validate { param($p) $hadErrorBefore = $script:HadError; $pwdOk = Test-UAGPasswordStrength -Password $p -Username $userDef["name"]; $script:HadError = $hadErrorBefore; $pwdOk } -AsPlainText
                                if(-not $userPass){
                                    MsgFce "WARN: Skipping API execution for user '$($userDef['name'])' (password is not available)." -Output warn
                                    continue
                                }
                            }

                            # Check password strength before calling REST API
                            if(-not (Test-UAGPasswordStrength -Password $userPass -Username $userDef["name"])){
                                MsgFce "WARN: Skipping API execution for user '$($userDef['name'])' due to password policy violation." -Output warn
                                continue
                            }

                            # Build user JSON payload matching UAG REST API specification
                            # (typed variable keeps a single role as an array - a single value from 'if' expression would be unrolled to string)
                            [string[]]$userRoles = if($userDef["roles"]){ $userDef["roles"] } else { "ROLE_MONITORING" }
                            $userPayload = [ordered]@{
                                name                              = $userDef["name"]
                                password                          = $userPass
                                enabled                           = if($userDef.ContainsKey("enabled")){ [bool]$userDef["enabled"] } else { $true }
                                roles                             = $userRoles
                                userType                          = if($userDef["userType"]){ $userDef["userType"] } else { "INTERNAL" }
                                adminMonitoringPasswordPreExpired = if($userDef.ContainsKey("adminMonitoringPasswordPreExpired")){ [bool]$userDef["adminMonitoringPasswordPreExpired"] } else { $false }
                            }
                            $userJson = ConvertTo-Json -InputObject $userPayload -Depth 5 -Compress

                            if($ValidateOnly){
                                MsgFce "INFO: VALIDATED user '$($userDef['name'])' (not sent - validation only)" -NoTimeStamp
                                $userPass = $null
                                continue
                            }

                            # Determine HTTP method based on existing username match
                            $userExists = $existingNames -contains $userDef["name"]
                            $httpMethod = if($userExists){ "Put" } else { "Post" }

                            MsgFce "INFO: $($httpMethod.ToUpper()) user '$($userDef['name'])' (Role: $($userRoles -join ',')) on UAG '$($uagNode.Name)'..."
                            $r = Invoke-UagApi -Method $httpMethod -Uri $uri -Body $userJson -Headers $uagAuthHeader -Label "User '$($userDef['name'])'"
                            if($r.Success){ MsgFce "SUCCESS: User '$($userDef['name'])' successfully applied via API" -Output success }
                            $userPass = $null
                        }
                        if($VAR.ApiStepDelay -gt 0){ Start-Sleep -Seconds $VAR.ApiStepDelay }
                        continue # Skip standard PUT execution below for "adminUsers" step
                    }


                    # API JSON Body
                    $json = ConvertTo-Json -InputObject $stepData -Depth 10 -Compress

                    if($ValidateOnly){
                        MsgFce "INFO: VALIDATED $($step.Name) (not sent - validation only)" -NoTimeStamp
                        continue
                    }

                    MsgFce "INFO: Configuring UAG $($step.Name)..."
                    $r = Invoke-UagApi -Method Put -Uri $uri -Body $json -Headers $uagAuthHeader -Label $step.Name
                    if($r.Success){ MsgFce "SUCCESS: $($step.Name) via API successfully applied" -Output success }

                    # Short delay between API steps
                    if($VAR.ApiStepDelay -gt 0){ Start-Sleep -Seconds $VAR.ApiStepDelay }
                }
            }

            # UAG Certificate upload
            $plan = $certPlan[$uagNode.Name]
            if($doCert -and $plan -and $plan.Requests){
                foreach($req in $plan.Requests){
                    if($script:UagAuthFailed){ break }
                    $uri = "$($uribase)$($req.Endpoint)"
                    $json = ConvertTo-Json -InputObject $req.Data -Depth 3 -Compress

                    if($ValidateOnly){
                        MsgFce "INFO: VALIDATED certificate '$($plan.Name)' [$($req.Entity)] (not sent - validation only)" -NoTimeStamp
                        continue
                    }

                    MsgFce "INFO: Uploading '$($plan.Name)' certificate (Entity: $($req.Entity)) to UAG '$($uagNode.Name)'..."
                    $r = Invoke-UagApi -Method Put -Uri $uri -Body $json -Headers $uagAuthHeader -Label "Applying certificate [$($req.Entity)] to UAG '$($uagNode.Name)'"
                    if($r.Success){
                        MsgFce "SUCCESS: The certificate '$($plan.Name)' [$($req.Entity)] was successfully applied to UAG '$($uagNode.Name)'" -Output success
                    }

                    # Short delay between certificate API steps
                    if($VAR.ApiStepDelay -gt 0){ Start-Sleep -Seconds $VAR.ApiStepDelay }
                }
            }
        } catch{
            # Error on this UAG only - the other UAGs are still processed
            $errMsg = $_.Exception.Message
            if($errMsg -notmatch '^ERROR:'){ $errMsg = "ERROR: Processing of UAG '$($uagNode.Name)' failed! $($errMsg)" }
            MsgFce $errMsg -Output error
        }
    }

    if($ValidateOnly){
        if($script:HadError){
            MsgFce "WARN: Validation finished WITH ERRORS - nothing was sent to UAG" -Output warn
        } else{
            MsgFce "SUCCESS: Validation finished successfully - nothing was sent to UAG" -Output success
        }
    }
} Catch {
    # Error Message handling
    $errMsg = $_.Exception.Message
    if($errMsg -notmatch '^ERROR:'){ $errMsg = "ERROR: $($errMsg)" }
    MsgFce $errMsg -Output error
} finally {
    # --- Cleanup of Sensitive Data ---
    $passwSec = $null
    $AdminPassword = $null
    $rad1Pass = $null
    $rad2Pass = $null
    $userPass = $null
    $uagCred = $null
    $uagAuthHeader = $null
    $certPlan = $null
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    [GC]::Collect()

    # --- Log Maintenance ---
    if($shouldLog -and $VAR.LogArchiveFiles -gt 0){ Remove-OldLogs -LogDir $LogDir -LogFileName $VAR.LogFileName -Keep $VAR.LogArchiveFiles }

    # --- End Message ---
    MsgFce "***** End of the script '$($VAR.ScriptName)' *****" -Output note -LinesBefore 1 -LinesAfter 1

    # --- Stop Transcript ---
    if($TranscriptOn){ Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }

    # --- Exit code (0 = OK, 1 = any error) ---
    if($script:HadError){ exit 1 } else{ exit 0 }
}

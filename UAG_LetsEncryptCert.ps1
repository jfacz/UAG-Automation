<#
.SYNOPSIS
   Automated Let's Encrypt Certificate lifecycle management for Omnissa Unified Access Gateway (UAG).

.DESCRIPTION
   Obtains and renews Let's Encrypt SSL certificates using Posh-ACME and automatically deploys
   PEM certificates to target Omnissa UAG appliances via UAG_Config.ps1.

.LINK
   https://github.com/jfacz/UAG-Automation

.NOTES
    Version:        2610.0
    Author:         Jan Fara
    Creation Date:  2026-10-01
    Last Update:    2026-10-31

   [v2610.0 - 20261031] Using shared functions in separated file 'fce_UAG_Automation.ps1'
                        Certificate is deployed to UAG only after a new order/renewal (or with -ForceDeploy)
                        Target UAG can be a list of names (cfg: TargetUAG = @("VDI-UAGE01","VDI-UAGE02")) or "ALL"; the list is passed to UAG_Config.ps1 in one call
                        Error handling: any failure ends the deployment (try/catch/finally), Email report is now sent from 'finally' block (also on failure) 
                        Non-interactive detection (no Read-Host hang in scheduled task)
                        Check of unfilled placeholders '<...>' in the configuration file (Confirm-NoPlaceholders)
                        Bug fixes and stability improvements
   [v2609.0 - 20260930] Complete rewrite with unified MsgFce output formatting
                        Added DPAPI credential storage for SMTP and DNS API secrets
                        Added automatic execution of UAG_Config.ps1 for cert deployment

.EXAMPLE
    # Execute interactive certificate automation with summary prompt
    .\UAG_LetsEncryptCert.ps1

.EXAMPLE
    # Execute non-interactive automated renewal (e.g. via Windows Task Scheduler)
    .\UAG_LetsEncryptCert.ps1 -Force

.EXAMPLE
    # Deploy the current (not renewed) certificate to UAG anyway
    .\UAG_LetsEncryptCert.ps1 -ForceDeploy

.EXAMPLE
    # Override target UAG appliance(s) and configuration file from CLI
    .\UAG_LetsEncryptCert.ps1 -ConfigFile "cfg_UAG_LetsEncryptCert.ps1" -TargetUAG "VDI-UAGE01","VDI-UAGE02" -Force
#>


# ==============================================================================
# Script Parameters
# ==============================================================================
param (
    [Parameter(Mandatory = $false, HelpMessage = "Path to Let's Encrypt Configuration File")]
    [string] $ConfigFile = "cfg_UAG_LetsEncryptCert.ps1",

    [Parameter(Mandatory = $false, HelpMessage = "Path to UAG Config script (UAG_Config.ps1)")]
    [string] $UagConfigScript,

    [Parameter(Mandatory = $false, HelpMessage = "Path to UAG configuration file (cfg_UAG.ps1, used by UAG_Config.ps1)")]
    [string] $UagCfg,

    [Parameter(Mandatory = $false, HelpMessage = "Target UAG appliance name(s) (comma separated) or 'ALL'")]
    [string[]] $TargetUAG,

    [Parameter(Mandatory = $false, HelpMessage = "ACME Server override (LE_STAGE or LE_PROD)")]
    [ValidateSet("LE_STAGE", "LE_PROD")]
    [string] $AcmeServer,

    [Parameter(Mandatory = $false, HelpMessage = "Bypass interactive prompts and summary confirmation")]
    [switch] $Force,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy the current certificate to UAG even when it was not issued/renewed")]
    [switch] $ForceDeploy,

    [Parameter(Mandatory = $false, HelpMessage = "Allow deployment of untrusted LE_STAGE certificate to UAG (testing only)")]
    [switch] $AllowStageDeploy
)

# --- Loading Required scripts ---
$psArr = @("fce_UAG_Automation.ps1")
foreach($ps in $psArr){
    $psPath = Join-Path $PSScriptRoot $ps
    if(-not (Test-Path $psPath -PathType Leaf)){ throw "ERROR: Unable to load required script. File '$($psPath)' not found!" }
    . $psPath
}
if(-not $FceVersion -or [version]$FceVersion -lt [version]"2610.0"){ throw "ERROR: Required script 'fce_UAG_Automation.ps1' is too old (version '$($FceVersion)', required 2610.0 or newer)!" }

# E-mail report: every message (without -NoAddToMail) is also appended to the HTML body; HTML tags are stripped on the console
$script:MsgFceStripHtml = $true
$script:MsgFceHook = { param($m) if($script:VAR -and $script:VAR.ContainsKey('EmailBody') -and $script:VAR.EmailBody -is [array]){ $script:VAR.EmailBody += $m } }

# Import Config File if Exist
$CfgFile = if([System.IO.Path]::IsPathRooted($ConfigFile)){ $ConfigFile } else { Join-Path $PSScriptRoot $ConfigFile }
if(!(Test-Path $CfgFile -PathType Leaf)){
    Write-Warning "Config File '$ConfigFile' doesn't exist. Cannot continue!!!"
    exit 1
}
. $CfgFile

# Prompts are possible = real user session AND not forced (a scheduled task runs in ConsoleHost too, but is not interactive)
$IsInteractive = (Test-IsInteractive) -and (-not $Force)
if($IsInteractive){ Clear-Host }

# ------------------------------------------------------------------------------
# Initialization & Parameter Merging
# ------------------------------------------------------------------------------
$LogDir          = Join-Path $VAR.ScriptPath $VAR.LogDir
$LogFile         = (Join-Path $LogDir $VAR.LogFileName) -f (Get-Date)
$SecCredDNSAPI   = Join-Path $VAR.ScriptPath $VAR.SecCredDNSAPI
$SecCredSMTP     = Join-Path $VAR.ScriptPath $VAR.SecCredSMTP
$SendEmail       = if($VAR.SendEmail -and $VAR.SmtpServer -ne ""){ $true } else { $false }

# Resolve UAG Config script path (CLI parameter takes precedence over Config)
$targetScript    = if([string]::IsNullOrWhiteSpace($UagConfigScript)){ $VAR.UagConfigScript } else { $UagConfigScript }
$UagConfigScript = if([System.IO.Path]::IsPathRooted($targetScript)){ $targetScript } else { Join-Path $VAR.ScriptPath $targetScript }

# Resolve UAG configuration file (CLI parameter takes precedence over Config)
$targetUagCfg    = if([string]::IsNullOrWhiteSpace($UagCfg)){ $VAR.UagCfgFile } else { $UagCfg }
$UagCfgFile      = if([string]::IsNullOrWhiteSpace($targetUagCfg)){ "cfg_UAG.ps1" } else { $targetUagCfg }

# Resolve Target UAG (CLI parameter takes precedence over Config)
if($TargetUAG){ $VAR.TargetUAG = $TargetUAG }
# Target UAG list: names from config/CLI, "ALL" (or nothing) = all UAGs of the inventory
$targetUagList = @($VAR.TargetUAG | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if(($targetUagList.Count -eq 0) -or ($targetUagList -contains "ALL")){ $targetUagList = @("ALL") }

# Resolve ACME Server (CLI parameter takes precedence over Config)
if(-not [string]::IsNullOrWhiteSpace($AcmeServer)){ $CERT.AcmeServer = $AcmeServer }

# Enforce TLS 1.2 protocol for all web requests (Posh-ACME & REST APIs)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# --- Status Variables (defined before 'Try' so 'finally' can always use them) ---
$script:HadError = $false # Any error occurred => exit code 1 + [FAILED] email
$CertNewOrder  = $false # New Certificate order
$CertRenew     = $false # Renew of Certificate
$CertApply     = $false # Apply Cert to UAG(s)
$PACert        = $null
$dnsApiSecret  = $null
$smtpUserPass  = $null
$TempFiles     = @()    # Temporary files removed in 'finally'

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
$TranscriptOn = Start-ScriptTranscript -LogDir $LogDir -LogFile $LogFile

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Sends the HTML email report (called from 'finally' => report is sent also when the run failed)
Function Send-EmailReport {
    if(-not $SendEmail){
        MsgFce "WARN: Email report was not sent - it's not configured" -Output warn -NoAddToMail
        return
    }

    # Optional: send only on certificate change or failure (cfg: $VAR.EmailOnlyOnEvent = $true)
    $onlyOnEvent = $VAR.ContainsKey('EmailOnlyOnEvent') -and $VAR.EmailOnlyOnEvent
    if($onlyOnEvent -and -not ($script:HadError -or $CertNewOrder -or $CertRenew)){
        MsgFce "INFO: Nothing to report (no new/renewed certificate, no error) - email report skipped" -NoAddToMail
        return
    }
    if(-not $VAR.EmailBody.Count){
        MsgFce "WARN: Email report was not sent - empty email body" -Output warn -NoAddToMail
        return
    }

    $status = if($script:HadError){ "FAILED" } elseif($CertNewOrder -or $CertRenew){ "RENEWED" } else { "OK" }

    $em = New-Object System.Net.Mail.MailMessage
    $smtp = $null
    try {
        $em.From = $VAR.EmailFrom
        $em.Subject = "[$($status)] " + ($VAR.EmailSubject -f ($CERT.Name))
        $em.IsBodyHtml = $true
        $emStyle = "<style>"
        $emStyle += "`n * {font-family:sans-serif}"
        $emStyle += "`n p {font-size:11pt;line-height:10pt;margin:0px;padding:0px}"
        $emStyle += "`n</style>`n"
        $em.Body = $emStyle + ($VAR.EmailBody -join "`n")
        $em.Body += "`n" + $VAR.EmailFooter -f ($VAR.Company)
        foreach($attachment in $VAR.EmailAttachments){
            if(Test-Path $attachment){ $em.Attachments.Add($attachment) }
        }
        foreach($to in $VAR.EmailTo){
            if(($to -notlike "") -and ($to -match $VAR.EmailRegEx)){ $em.To.Add($to) }
        }

        if(-not $em.To.Count){
            MsgFce "WARN: Email report was not sent - no valid recipient specified" -Output warn -NoAddToMail
            return
        }

        # Enforce TLS 1.2 globally for SmtpClient
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $smtp = New-Object System.Net.Mail.SmtpClient($VAR.SmtpServer, [int]$VAR.SmtpPort)
        # Set explicit timeout to 15 seconds (15000 ms) to prevent long freezes
        $smtp.Timeout = 15000
        if($VAR.SmtpSSL){ $smtp.EnableSsl = $true }
        if($VAR.SmtpUser -notlike ""){
            $smtpUserPass = Get-DpapiSecret -FilePath $SecCredSMTP -Description "password for SMTP server '$($VAR.SmtpServer)'"
            if(-not $smtpUserPass){ throw "SMTP password DPAPI file '$($SecCredSMTP)' is missing or could not be decrypted." }
            $smtp.Credentials = [System.Net.NetworkCredential]::new($VAR.SmtpUser, $smtpUserPass)
        }
        $smtp.Send($em)
        MsgFce "SUCCESS: Email report [$($status)] successfully sent to: $([system.String]::Join(', ',$em.To))" -Output success -NoAddToMail
    } catch {
        MsgFce "ERROR: Email report was not sent! Error details: $($_.Exception.Message)" -Output error -NoAddToMail
    } finally {
        if($smtp){ $smtp.Dispose() }
        $em.Dispose()
    }
}

# ==============================================================================

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
Try{
    MsgFce "***** The beginning of the script '$($VAR.ScriptName)' *****" -Output note -LinesAfter 1 -NoAddToMail

    # Stop execution if the config file contains unfilled <...> placeholders (allowed in EmailFrom, EmailFooter and EmailBody).
    try {
        $cfgName  = Split-Path $CfgFile -Leaf
        $varCheck = @{}
        foreach($k in $VAR.Keys){ if($k -notin @("EmailFrom", "EmailFooter", "EmailBody")){ $varCheck[$k] = $VAR[$k] } }
        Confirm-NoPlaceholders -Data $varCheck -Path "VAR"    -Context "configuration file '$($cfgName)'"
        Confirm-NoPlaceholders -Data $CERT     -Path "CERT"   -Context "configuration file '$($cfgName)'"
        Confirm-NoPlaceholders -Data $DNSAPI   -Path "DNSAPI" -Context "configuration file '$($cfgName)'"
    } catch {
        $SendEmail = $false   # misconfiguration => no email report (e-mail settings may be unfilled as well)
        throw
    }

    # --- Interactive Safety Confirmation Prompt ---
    if($IsInteractive){
        MsgFce "Summary of Let's Encrypt Execution Parameters:" -Output verbose -NoTimeStamp -NoAddToMail
        MsgFce "  - Certificate Subject : $($CERT.Name)" -NoTimeStamp -NoAddToMail
        MsgFce "  - Domain SAN(s)       : $([system.String]::Join(', ',$CERT.Domain))" -NoTimeStamp -NoAddToMail
        MsgFce "  - ACME Server Mode    : $($CERT.AcmeServer)" -NoTimeStamp -NoAddToMail
        MsgFce "  - DNS API Provider    : $($DNSAPI.PluginName)" -NoTimeStamp -NoAddToMail
        MsgFce "  - Target UAG Appliance: $($targetUagList -join ', ')" -NoTimeStamp -NoAddToMail
        MsgFce "  - UAG Config script   : $([System.IO.Path]::GetFileName($UagConfigScript)) (Cfg: '$UagCfgFile')" -NoTimeStamp -NoAddToMail
        MsgFce "  - Email Notifications : $(if($SendEmail){ 'ENABLED (' + ($VAR.EmailTo -join ', ') + ')' } else { 'DISABLED' })" -NoAddToMail -NoTimeStamp -LinesAfter 1

        # Extra menu option: deploy to UAG now (-ForceDeploy); with LE_STAGE (untrusted) it also sets -AllowStageDeploy
        $isStage     = ($CERT.AcmeServer -like "LE_STAGE") -and -not $AllowStageDeploy
        $optDeploy   = if($isStage){ "Yes + deploy to UAG now (UNTRUSTED LE_STAGE certificate!)" } else { "Yes + deploy to UAG now (even if not renewed)" }
        $menuItems   = @("No", "Yes")
        if($isStage -or -not $ForceDeploy){ $menuItems += $optDeploy }
        $confirm = MenuSimple -MenuItems $menuItems -Title "Do you want to proceed with Let's Encrypt certificate processing and deployment?" -StartFrom 0
        if($confirm -eq $optDeploy){ $ForceDeploy = $true; if($isStage){ $AllowStageDeploy = $true } }
        elseif($confirm -ne "Yes"){
            MsgFce "WARN: Operation aborted by user (exit)." -Output warn -LinesBefore 1 -NoTimeStamp -NoAddToMail
            $SendEmail = $false
            return
        }
    }

    MsgFce "<h1>$($VAR.ScriptName)</h1>" -NoTimeStamp -LinesBefore 1
    MsgFce "<h3>Certificate CN: '$($CERT.Name)'</h3>" -NoTimeStamp
    MsgFce "<h3>Certificate Domain(s): '$([system.String]::Join("', '",$CERT.Domain))'</h3>" -NoTimeStamp -LinesAfter 1

    # --- Security Credentials Verification (DPAPI) ---
    if($SendEmail -and $VAR.SmtpUser -notlike ""){
        $null = Get-DpapiSecret -FilePath $SecCredSMTP -Description "password for SMTP server '$($VAR.SmtpServer)'"
    }
    $dnsApiSecret = Get-DpapiSecret -FilePath $SecCredDNSAPI -Description "DNS API secret for plugin '$($DNSAPI.PluginName)'"
    if(-not $dnsApiSecret){
        MsgFce "<p style=""color:red""><b>ERROR:</b> DNS API secret is not available (file '$($SecCredDNSAPI)'). Cannot continue!</p>" -Output error -NoTimeStamp
        return
    }

    # --- Verify presence of UAG Config script ---
    if(!(Test-Path $UagConfigScript -PathType Leaf)){
        MsgFce "<p style=""color:red""><b>ERROR:</b> UAG Config script '$($VAR.UagConfigScript)' was not found at path '$($UagConfigScript)'!</p>" -Output error -NoTimeStamp
        return
    }

    # --- Import & Configure Posh-ACME Module ---
    # Settings of custom Home Directory
    if($VAR.PoshAcmeHomeDir -notlike ""){
        $dir = Join-Path $VAR.ScriptPath $VAR.PoshAcmeHomeDir
        if(!(Test-Path $dir -PathType Container)){ New-Item -Path $dir -ItemType Directory | Out-Null }
        $env:POSHACME_HOME = $dir
        MsgFce "<p>INFO: Posh-ACME Config directory set to: <i style=""font-size:90%"">$($dir)</i></p>" -Output note -NoTimeStamp
    }
    # Settings of custom Plugin Directory
    if($VAR.PoshAcmePluginDir -notlike ""){
        $dir = Join-Path $VAR.ScriptPath $VAR.PoshAcmePluginDir
        if(Test-Path $dir -PathType Container){
            $env:POSHACME_PLUGINS = $dir
            MsgFce "<p>INFO: Posh-ACME Plugin directory set to: <i style=""font-size:90%"">$($dir)</i></p>" -Output note -NoTimeStamp
        }
    }
    # Checking Posh-ACME module
    if(!((Get-Module -ListAvailable -Name "Posh-ACME") -or (Get-Module -Name "Posh-ACME"))){
        MsgFce "<p style=""color:red""><b>ERROR:</b> Required module 'Posh-ACME' not found!</p>" -Output error -NoTimeStamp
        return
    }
    Import-Module Posh-ACME -Force

    # Set ACME Server
    if($CERT.AcmeServer -like "LE_STAGE"){
        MsgFce "<p>INFO: Posh-ACME Server set to 'LE_STAGE' (Test)</p>" -NoTimeStamp
        Set-PAServer LE_STAGE -ErrorAction Stop
    } elseif($CERT.AcmeServer -like "LE_PROD"){
        MsgFce "<p>INFO: Posh-ACME Server set to 'LE_PROD' (Production)</p>" -NoTimeStamp
        Set-PAServer LE_PROD -ErrorAction Stop
    } else {
        MsgFce "<p><b style=""color:red"">ERROR:</b> Unknown Posh-ACME Server '$($CERT.AcmeServer)'. Cannot continue.</p>" -Output error -NoTimeStamp
        return
    }

    # Safe check for existing certificate order
    $PACert = try { Get-PACertificate -MainDomain $CERT.Name -ErrorAction Stop } catch { $null }
    $PAOrder = $null

    if(!$PACert){
        $CertNewOrder = $true
        MsgFce "<p><b style=""color:orange"">WARN:</b> Certificate order with Subject '$($CERT.Name)' does not exist => Processing new order...</p>" -Output warn
    } else {
        MsgFce "<p>INFO: Details of certificate '$($CERT.Name)'</p>"
        $dateNotAfter = (Get-Date $PACert.NotAfter)
        MsgFce "<p style=""font-size:80%; font-style:italic"">Subject: '$($PACert.Subject)', SAN(s): '$($PACert.AllSANs -join ', ')', Expiration: '$($dateNotAfter.ToString('yyyy-MM-dd HH:mm:ss'))'</p>" -Output info -NoTimeStamp
        # Details of Cert Order
        $PAOrder = Get-PAOrder -MainDomain $CERT.Name
    }

    # Verify if renewal is needed
    if($PAOrder){
        $dateRenewAfter = (Get-Date $PAOrder.RenewAfter)
        if($dateRenewAfter -lt (Get-Date)){
            $CertRenew = $true
            MsgFce "<p><b style=""color:orange"">WARN:</b> Certificate '$($CERT.Name)' is eligible for renewal (RenewAfter date: '$($dateRenewAfter.ToString('yyyy-MM-dd HH:mm:ss'))') => Renewal will be processed...</p>" -Output warn
        } else {
            MsgFce "<p>INFO: Renewal is not needed yet. Next renewal date after '$($dateRenewAfter.ToString('yyyy-MM-dd HH:mm:ss'))'</p>"
        }
    }

    # Posh-ACME Plugin Settings (dynamic arguments builder)
    $pArgs = @{}

    # 1. Add static ExtraArgs if defined
    if($DNSAPI.ContainsKey('ExtraArgs') -and $DNSAPI.ExtraArgs -is [hashtable]){
        foreach($key in $DNSAPI.ExtraArgs.Keys){ 
            $pArgs[$key] = $DNSAPI.ExtraArgs[$key] 
        }
    }
    # 2. Add Login parameter if required (e.g., WgLogin for Webglobe)
    if(-not [string]::IsNullOrWhiteSpace($DNSAPI.LoginParamName) -and $DNSAPI.Login){
        $pArgs[$DNSAPI.LoginParamName] = $DNSAPI.Login
    }
    # 3. Add Secret parameter (PSCredential vs SecureString)
    if(-not [string]::IsNullOrWhiteSpace($DNSAPI.SecretParamName)){
        if($DNSAPI.SecretType -eq "PSCredential"){
            # Create PSCredential object using Login (or fallback 'api') and DPAPI SecureString
            $user = if($DNSAPI.Login){ $DNSAPI.Login } else { "api" }
            $pArgs[$DNSAPI.SecretParamName] = New-Object System.Management.Automation.PSCredential($user, $dnsApiSecret)
        } else {
            # Standard SecureString
            $pArgs[$DNSAPI.SecretParamName] = $dnsApiSecret
        }
    }

    # DNS propagation wait in seconds (optional cfg: $DNSAPI.DnsSleep, default 120 = Posh-ACME default)
    $dnsSleep = if($DNSAPI.ContainsKey('DnsSleep') -and $DNSAPI.DnsSleep){ [int]$DNSAPI.DnsSleep } else { 120 }

    # --- New Certificate Order ---
    # No '-ErrorAction' here (Posh-ACME fails with a duplicate parameter) => errors are made terminating by $ErrorActionPreference
    if($CertNewOrder){
        $eapOld = $ErrorActionPreference; $ErrorActionPreference = "Stop"
        try { New-PACertificate -Domain $CERT.Domain -AcceptTOS -Contact $CERT.Contact -Plugin $DNSAPI.PluginName -PluginArgs $pArgs -DnsSleep $dnsSleep | Out-Null }
        finally { $ErrorActionPreference = $eapOld }
    }

    # --- Renewal of Certificate ---
    $oldThumbprint = if($PACert){ $PACert.Thumbprint } else { $null }
    if($CertRenew){
        $eapOld = $ErrorActionPreference; $ErrorActionPreference = "Stop"
        try { Submit-Renewal -MainDomain $CERT.Name -PluginArgs $pArgs -Force | Out-Null }
        finally { $ErrorActionPreference = $eapOld }
    }

    # Fetch updated certificate details
    if($CertNewOrder -or $CertRenew){
        $PACert = Get-PACertificate -MainDomain $CERT.Name -ErrorAction SilentlyContinue
        if($PACert -and ($CertNewOrder -or ($PACert.Thumbprint -ne $oldThumbprint))){
            $m = if($CertNewOrder){ "<p><b style=""color:green"">SUCCESS:</b> The certificate '$($CERT.Name)' was successfully issued!</p>" } else { "<p><b style=""color:green"">SUCCESS:</b> The certificate '$($CERT.Name)' was successfully renewed!</p>" }
            MsgFce $m -Output success
            $CertApply = $true
            # if cert OK simulating of PAOrder valid status (for direct apply of cert)
            $PAOrder = @{ status = "valid" }
        } else {
            # Renewal returned the same certificate => nothing was really renewed
            $CertRenew = $false
            $CertNewOrder = $false
            MsgFce "<p><b style=""color:red"">ERROR:</b> Certificate '$($CERT.Name)' was NOT renewed (no new certificate was produced)!</p>" -Output error
        }
    }

    # Validation of Certificate status and date
    if($PACert -and -not $script:HadError){
        $dateStart = Get-Date $PACert.NotBefore
        $dateEnd   = Get-Date $PACert.NotAfter
        $certValid = (($dateStart -le (Get-Date)) -and ($dateEnd -ge (Get-Date)) -and ($PAOrder.status -like "valid"))
        if(-not $certValid){
            $CertApply = $false
            MsgFce "<p><b style=""color:red"">ERROR:</b> Certificate is not valid or order state is invalid! Certificate will NOT be applied to UAG(s).</p>" -Output error
        } elseif($CertNewOrder -or $CertRenew -or $ForceDeploy){
            $CertApply = $true
        } else {
            $CertApply = $false
            MsgFce "<p>INFO: Certificate is valid and was not renewed => deployment to UAG skipped (use -ForceDeploy to deploy it anyway)</p>"
        }
    } elseif($script:HadError){
        $CertApply = $false
    }

    # Safety guard: never deploy untrusted STAGE certificate to UAG
    if($CertApply -and ($CERT.AcmeServer -like "LE_STAGE") -and -not $AllowStageDeploy){
        $CertApply = $false
        MsgFce "<p><b style=""color:orange"">WARN:</b> Certificate was issued by LE_STAGE (untrusted) => deployment to UAG skipped (use -AllowStageDeploy to override)</p>" -Output warn
    }

    # --- Upload Certificate to UAG(s) via UAG Config script (it handles the list of UAGs itself) ----
    if($CertApply){
        $targetUagName = $targetUagList -join ","
        MsgFce "<p>INFO: Certificate status and date are valid. Uploading Certificate to UAG Appliance(s) '$($targetUagName)' via '$([System.IO.Path]::GetFileName($UagConfigScript))'...</p>"
        # Execute UAG Config script in silent mode (output captured to temp file => into transcript/log)
        try {
            $tmpOut = [System.IO.Path]::GetTempFileName()
            $tmpErr = [System.IO.Path]::GetTempFileName()
            $TempFiles += $tmpOut, $tmpErr

            $uagParams = @{
                FilePath               = "powershell.exe"
                ArgumentList           = @(
                    "-NonInteractive",
                    "-ExecutionPolicy", "Bypass",
                    "-File", "`"$UagConfigScript`"",
                    "-UagCfg", "`"$UagCfgFile`"",
                    "-Mode", "CfgCertOnly",
                    "-TargetUAG", "`"$targetUagName`"",
                    "-CertPem", "`"$($PACert.FullChainFile)`"",
                    "-CertKeyPem", "`"$($PACert.KeyFile)`""
                )
                NoNewWindow            = $true
                Wait                   = $true
                PassThru               = $true
                RedirectStandardOutput = $tmpOut
                RedirectStandardError  = $tmpErr
            }

            MsgFce "<p><i style=""font-size:90%"">Invoking: '$($UagConfigScript)' -UagCfg '$UagCfgFile' -Mode CfgCertOnly -TargetUAG '$targetUagName' -CertPem '$($PACert.FullChainFile)' -CertKeyPem '$($PACert.KeyFile)'</i></p>" -Output verbose
            $process = Start-Process @uagParams
            $null = $process.Handle # required, otherwise ExitCode can be empty with -NoNewWindow -PassThru

            # Child output into console/transcript
            $childOut = Get-Content $tmpOut -ErrorAction SilentlyContinue
            $childErr = Get-Content $tmpErr -ErrorAction SilentlyContinue
            if($childOut){ $childOut | ForEach-Object { Write-Host "    | $($_)" -ForegroundColor DarkGray } }
            if($childErr){ $childErr | ForEach-Object { Write-Host "    | $($_)" -ForegroundColor Red } }

            # Child errors (lines starting with timestamp + ERROR) into email as well
            $childErrLines = @($childOut | Where-Object { $_ -match '\bERROR:' })

            if($process.ExitCode -eq 0 -and -not $childErrLines){
                MsgFce "<p><b style=""color:green"">SUCCESS:</b> SSL Certificate '$($CERT.Name)' was successfully deployed to UAG target '$($targetUagName)'</p>" -Output success
            } else {
                MsgFce "<p><b style=""color:red"">ERROR:</b> SSL Certificate '$($CERT.Name)' deployment failed on UAG target '$($targetUagName)' (ExitCode: $($process.ExitCode))</p>" -Output error
                foreach($l in ($childErrLines | Select-Object -First 10)){
                    $VAR.EmailBody += "<p style=""font-size:85%; color:red"">$([System.Net.WebUtility]::HtmlEncode($l))</p>"
                }
            }
        } catch {
            MsgFce "<p><b style=""color:red"">ERROR:</b> Failed to invoke '$($VAR.UagConfigScript)'! Error details: $($_.Exception.Message)</p>" -Output error
        }
    }

    # Add Certificate storage info and attach ZIP file for Email (only when certificate has changed)
    if(($CertNewOrder -or $CertRenew) -and $PACert -and ($PACert.CertFile -notlike "")){
        $certPath = Split-Path -Parent $PACert.CertFile
        MsgFce "<p>INFO: Certificate storage location (on server '$($ENV:COMPUTERNAME)'): <i style=""font-size:90%"">$($certPath)</i></p>"
        # Create a zip and attach it to an email (public part only - no private key)
        if($SendEmail){
            try {
                # Expand 8.3 short paths to full long paths to prevent Compress-Archive 8.3 path bug
                $tempLongDir = (Get-Item $Env:Temp).FullName
                $zipFile     = Join-Path $tempLongDir "cert_$($CERT.Name).zip"
                $files2Zip = @(
                    (Get-Item $PACert.CertFile).FullName,
                    (Get-Item $PACert.FullChainFile).FullName
                )
                # Compress all files at once using -Force
                Compress-Archive -Path $files2Zip -DestinationPath $zipFile -Force -ErrorAction Stop
                $VAR.EmailAttachments += $zipFile
                $TempFiles += $zipFile
                MsgFce "<p>INFO: Certificate files attached to email report as ZIP archive.</p>"
            } catch {
                MsgFce "<p><b style=""color:red"">WARN:</b> Failed to create ZIP archive for email: $($_.Exception.Message)</p>" -Output warn
            }
        }
    }
} Catch {
    # Error Message handling
    MsgFce $_.Exception.Message -Output error
} finally {
    # --- Emailing (always - also after failure) ---
    try { Send-EmailReport } catch { Write-Warning "Email report failed: $($_.Exception.Message)"; $script:HadError = $true }

    # --- Cleanup of Sensitive Data & Temp Files ---
    $dnsApiSecret = $null
    $smtpUserPass = $null
    $pArgs        = $null
    foreach($tf in $TempFiles){ Remove-Item $tf -Force -ErrorAction SilentlyContinue }

    # --- Log Maintenance ---
    if($VAR.LogArchiveFiles -gt 0){ Remove-OldLogs -LogDir $LogDir -LogFileName $VAR.LogFileName -Keep $VAR.LogArchiveFiles }

    # --- End Message ---
    MsgFce "***** End of the script '$($VAR.ScriptName)' *****" -Output note -LinesBefore 1 -LinesAfter 1 -NoAddToMail

    # --- Stop Transcript ---
    if($TranscriptOn){ Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }

    # Exit code for Task Scheduler / callers (0 = OK, 1 = any error). Must be inside 'finally' - 'return' in 'Try' ends the script before any code placed after it
    if($script:HadError){ exit 1 } else { exit 0 }
}

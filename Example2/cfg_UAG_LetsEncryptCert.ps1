<#
.SYNOPSIS
   Let's Encrypt certificate configuration for UAG_LetsEncryptCert.ps1

.DESCRIPTION
   Defines script and environment settings ($VAR), the certificate ($CERT) and the DNS provider API ($DNSAPI)
   used to automatically request, renew and deploy SSL certificates.

   Values in the form <...> are placeholders - the script aborts until they are replaced with real values (or removed).

.LINK
   https://github.com/jfacz/UAG-Automation
#>

# ==============================================================================
# 1. GLOBAL ENVIRONMENT & SCRIPT SETTINGS ($VAR)
# ==============================================================================
$VAR = @{
 # Company Name
  Company = "<Company Name>"
 # Script Name
  ScriptName = "UAG Let's Encrypt Certificate Automation"
 # Script Path ($PSScriptRoot for CurrentPath)
  ScriptPath = $PSScriptRoot

 # --- Posh-ACME Environment Directories ---
 # Custom Home Directory relative to ScriptPath (leave empty for default %LOCALAPPDATA%\Posh-ACME)
  PoshAcmeHomeDir = "Posh-ACME"
 # Custom Plugin Directory relative to ScriptPath (leave empty for default module path)
  PoshAcmePluginDir = "Plugins"

 # --- UAG Config script integration ---
 # Path to UAG_Config.ps1 script (relative to ScriptPath or absolute)
  UagConfigScript = "UAG_Config.ps1"
 # Path to UAG configuration file used by UAG_Config.ps1
  UagCfgFile      = "cfg_UAG.ps1"
 # Target UAG appliance(s) for certificate deployment: "ALL" (all UAGs of the inventory), one name "UAG-EXT-01" or a list @("UAG-EXT-01","UAG-EXT-02")
  TargetUAG = @("VDI-UAGE01", "VDI-UAGE02")

 # --- Log Settings ---
  LogDir = "Logs"
  LogFileName = "UAG_LetsEncryptCert_{0:yyyyMMdd_HHmmss}.txt" # 0 = DateTime
  LogArchiveFiles = 6

 # --- EMAIL ---
 # Email report - Settings
  SendEmail = $true
  EmailOnlyOnEvent = $true    # $true = send the report only after a new/renewed certificate or on error
  SmtpServer = "<smtp.company.com>" #"smtp.office365.com"
  SmtpPort = "587" # 25 | 587
  SmtpUser = ""
  SmtpSSL = $true
  EmailFrom = "Company VDI <vdi@company.com>" # (not checked for placeholders - adjust it)
  EmailTo = @("<admin@company.com>") #@("<admin@company.com>", "<helpdesk@company.com>")
  EmailSubject = "UAG Let's Encrypt Certificate [{0}]" # 0 = $CERT.Name
  EmailBody = @()
  EmailAttachments = @()
  EmailFooter = "<br /><p>Best regards</p><p>{0} Automator</p>" # 0 = $VAR.Company
 # Email Validity RegEx
  EmailRegEx = "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@([^.]+[.])+[a-zA-Z]{2,5}$"

 # --- Security & Credentials (DPAPI) ---
 # Credential files stored via Windows DPAPI per computer and user account
  SecCredSMTP   = "sec_smtp_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
  SecCredDNSAPI = "sec_dnsapi_$($env:COMPUTERNAME)_$($env:USERNAME).txt"
}

# ==============================================================================
# 2. CERTIFICATE DEFINITIONS ($CERT)
# ==============================================================================
$CERT = @{
 # Certificate Name (The identifier of the ACME order, usually MainDomain)
  Name = "<vdi.company.com>"

 # Certificate Domain(s)
 # Quote and comma delimited list of domain names (SANs) for the certificate: "host1.domain.com","host2.domain.com",host3.domain.com"
 # For Wildcard certificate use format: "*.domain.com","domain.com"
 # First entry should be the same as Name
  Domain = "<vdi.company.com>"

 # Certificate Contact Email
 # Email address associated with your Let's Encrypt ACME account
  Contact = "<it@company.com>"

 # ACME Server Mode (ACME address in Posh-ACME definition)
 # Let's Encrypt: LE_STAGE = Test environment (no rate limits, untrusted certificate - NOT deployed to UAG), LE_PROD = Production environment
  AcmeServer = "LE_STAGE"
}

# ==============================================================================
# 3. DNS REST API CONFIGURATION ($DNSAPI)
# ==============================================================================
# Active DNS Provider: Cloudflare
# Posh-ACME supports many DNS providers (https://poshac.me/docs/latest/Plugins/) - use the plugin name and the
# parameter names of your provider (see the plugin's documentation) and keep the secret out of this file (DPAPI).
$DNSAPI = @{
  PluginName      = "Cloudflare"
  SecretParamName = "CFToken"
  SecretType      = "SecureString"  # "SecureString" | "PSCredential"
  ExtraArgs       = @{} # Plugin Specific arguments
}

<#
# Example provider: AWS Route 53
$DNSAPI = @{
  PluginName      = "Route53"
  SecretParamName = "R53SecretKey"
  SecretType      = "SecureString"
  LoginParamName  = "R53AccessKey"
  Login           = "<AccessKeyId>"
  ExtraArgs       = @{} # Plugin Specific arguments
}

# Example provider: GoDaddy
$DNSAPI = @{
  PluginName      = "GoDaddy"
  SecretParamName = "GDSecret"
  SecretType      = "SecureString"
  LoginParamName  = "GDKey"
  Login           = "<ApiKey>"
  ExtraArgs       = @{} # Plugin Specific arguments
}
#>

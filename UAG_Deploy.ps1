<#
.SYNOPSIS
   Automated deployment script for Omnissa Unified Access Gateway (UAG) via PowerCLI.

.DESCRIPTION
   Deploys Omnissa UAG OVA appliances into VMware vSphere using PowerCLI with complete automation.
   Handles OVF properties, vSphere VM Notes, and triggers automated REST API configuration.

.PROJECTURI https://github.com/jfacz/UAG-Automation

.NOTES
   Version:        2609.0
   Author:         Jan Fara
   Creation Date:  2026-08-21
   Last Update:    2026-09-14

.RELEASENOTES
   [v2609.0 - 20260914] Added support to call UAG API Management Script for full automatic configuration of UAG
                        Bug fixes and improvements
   [v2608.0 - 20260821] Rewrote the previous simpler version of the script into a new universal deployment script
#>

# ==============================================================================
# SETTINGS
# ==============================================================================
# --- UAG OVA Templates Repository ---
$OVA_Repo = @{
    "2606" = "C:\Install\UAG\euc-unified-access-gateway-26.06.0.0-32063449787_OVF10.ova"
}

# --- vSphere / vCenter Configuration ---
$vSphere = @{
 # vCenter Server FQDN
  VIServer            = "vcenter.company.com"
 # vCenter User Account
  VIUsername          = "vcenter-admin@company.com"
 # vCenter User Password (if empty, the script will securely prompt)
  VIPassword          = ""
 # Target vSphere Cluster
  TargetCluster       = "Production-Cluster"
 # Target vSphere Host Name or "*random*" for a random powered-on host
  TargetHostName      = "*random*"
 # Target Datastore Name or "*random*"
  TargetDatastoreName = "vsanDatastore"
 # Optional: Target vSphere Inventory VM Folder path (leave empty if not used)
  TargetFolder        = "VDI\UAG"
 # Optional: Target vSphere Resource Pool (leave empty if not used)
  TargetResourcePool  = ""         
}

# --- UAG Base Configuration ---
$UAG_base = @{
 # UAG / VM Name
  uagName          = "UAG-EXT-01"
 # Specify UAG version key from $OVA_Repo or leave empty for latest
  uagVersion       = ""
 # VM Notes vSphere (multi-line using `n) - supports variables %uagName%, %uagVersion%, %date% [yyyy-MM-dd]
  vmNotes          = "Omnissa EUC Unified Access Gateway`nUAG Name: %uagName%`nUAG Version: %uagVersion%`nDate of deploy: %date%"
 # Deployment Size: "onenic", "twonic", "threenic", "onenic-large", "twonic-large", "threenic-large", "onenic-XL", "twonic-XL", "threenic-XL"
  DeploymentOption = "onenic"
 # Automatic Power-On and REST API configuration
  UagPowerOn       = $true   # Start VM after deployment is complete
  UagConfig        = $true   # Automatically run UAG API management script after power-on
 # root & admin password (if empty, the script will securely prompt and check complexity)
  rootPassword     = ""
  adminPassword    = ""
 # Network Portgroup Mapping (Internet = eth0, ManagementNetwork = eth1, BackendNetwork = eth2)
  Internet          = "DMZ-PortGroup"
  ManagementNetwork = "DMZ-PortGroup"
  BackendNetwork    = "DMZ-PortGroup"
 # Shared Network Settings
  IpProtocol     = "IPv4" # IPv4 | IPv6
  defaultGateway = "10.0.10.1"
  DNS            = "10.0.1.10 10.0.1.11" # Space separated
  dnsSearch      = "company.com"
 # Network Settings NIC1 [eth0]
  ipMode0        = "STATICV4"
  ip0            = "10.0.10.11"
  netmask0       = "255.255.255.0"
  routes0        = ""
 # Network Settings NIC2 [eth1] (if twonic/threenic used)
  ipMode1        = "STATICV4"
  ip1            = ""
  netmask1       = ""
  routes1        = ""
 # Network Settings NIC3 [eth2] (if threenic used)
  ipMode2        = "STATICV4"
  ip2            = ""
  netmask2       = ""
  routes2        = ""
}

# --- UAG Advanced Configuration ---
$UAG_advanced = @{
 # Network Advanced Settings
  forwardrules     = ""
  eth0CustomConfig = "" 
  eth1CustomConfig = ""
  eth2CustomConfig = ""
 # SSH Settings
  sshEnabled               = $false   # default: false 
  sshKeyAccessEnabled      = $false   # default: false
  sshPasswordAccessEnabled = $true    # default: true
  sshInterface             = ""       # # string["", "eth0", "eth1", "eth2"]. If not provided (empty), SSH will be enabled on all interface
  sshPort                  = ""       # if not provided (empty) it will be enabled on the default port 22
  sshLoginBannerText = @"
--------------------------------------------------
  Omnissa EUC Unified Access Gateway
  UAG Name: %uagName%
  UAG Version: %uagVersion%
  IP0: %ip0%, IP1: %ip1%, IP2: %ip2%
  Management URL: https://%ip1%:9443/admin
--------------------------------------------------
"@
 # Password Policy and Session Management (admin/root)
  adminPasswordPolicyFailedLockoutCount = 3    # default: 3; accept 1 to 100
  adminPasswordPolicyMinLen             = 8    # default: 8
  adminPasswordPolicyUnlockTime         = 5    # default: 5; accept 1 to 9999
  adminSessionIdleTimeoutMinutes        = 10   # default: 10; 0 for never; max 1440
  adminMaxConcurrentSessions            = 5    # default: 5; max 50
  passwordPolicyFailedLockout           = 3    # default: 3; accept 1 to 10
  passwordPolicyMinClass                = 3    # default: 1; accept 1 to 4 
  passwordPolicyMinLen                  = 8    # default: 6; accept 6 to 64
  passwordPolicyUnlockTime              = 900  # default: 900; accept 1 to 3600
  rootPasswordExpirationDays            = 0    # default: 365; 0 for never
  rootSessionIdleTimeoutSeconds         = 300  # default: 300; 0 for never; accept 30 to 3600
 # Other System Parameters
  ceipEnabled             = $false             # default: false
  secureRandomSource      = "Default"          # When set to Default, '/dev/random' is used in Non-FIPS mode and '/dev/urandom' is used in FIPS mode
  osLoginUsername         = ""                 # Custom Admin name (disables root if selected)
  osMaxLoginLimit         = ""                 # Maximum limit for concurrent sudo user logins; default 10
  commandsFirstBoot       = ""
  commandsEveryBoot       = ""
  enabledAdvancedFeatures = ""                 # Comma separated list of advanced features
}

# --- UAG Post-Deployment Configuration ---
# Settings for UAG API Management Script executed after deployment and power-on
$UAG_ApiCfg = @{
    ScriptName = "UAG_API_Manage.ps1" # Relative to script folder or full path
    SecCredUAG = "sec_uag_{0}_$($env:COMPUTERNAME)_$($env:USERNAME).txt" # template/filemask of DPAPI file for UAG credentials (from $UAG_ApiCfg.ScriptName)

    # Script parameters passed directly to $UAG_ApiCfg.ScriptName
    Params = @{
        UagCfg   = "cfg_UAG.ps1"
        Mode     = "CfgConfigAndCert" # CfgConfigOnly | CfgCertOnly | CfgConfigAndCert
        CertName = "vdi.company.com (exp. 2027-01) [PFX]" # if CertName contains "*PFX*" or "*.pfx" script will prompt for PFX password
    }
}
# ==============================================================================

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Script Messages Function
Function MsgFce{
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
    # Padding: Empty Lines Before
    if($LinesBefore){ 1..$LinesBefore | ForEach-Object{ Write-Host "" } }
    # Msg
    $Msg = if($NoTimeStamp){ $Msg } else{ "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Msg }
    if($Output -eq "return"){ return "`r`n$($Msg)" }

    # Write-Host Msg
    $WriteHostArgs = @{ Object = $Msg }
    if($Color){ $WriteHostArgs.ForegroundColor = $Color }
    if($Output -eq "header"){
        $border = "-" * ($Msg.Length + 4)
        $WriteHostArgs.Object = "$($border)`n  $($Msg.ToUpper())`n$($border)"
        Write-Host @WriteHostArgs
    } else{
        Write-Host @WriteHostArgs
    }
    # Padding: Empty Lines After
    if($LinesAfter){ 1..$LinesAfter | ForEach-Object { Write-Host "" } }
}

# Password Complexity Checker
Function Test-UAGPasswordStrength {
    param(
        [Parameter(Mandatory=$true)] [System.Security.SecureString]$Password,
        [Parameter(Mandatory=$true)] [string]$FieldName,
        [int]$MinLength = 8,
        [int]$MinClass = 3
    )
    # Securely retrieve the plain text for complexity evaluation
    $plainPassword = [System.Net.NetworkCredential]::new("", $Password).Password
    if($plainPassword.Length -lt $MinLength){
        MsgFce "ERROR: Password for '$($FieldName)' must have at least $($MinLength) characters!" -Output error
        return $false
    }
    $classCount = 0
    if($plainPassword -match '[0-9]'){ $classCount++ } # Digits
    if($plainPassword -match '[A-Z]'){ $classCount++ } # Uppercase letters
    if($plainPassword -match '[a-z]'){ $classCount++ } # Lowercase letters
    if($plainPassword -match '[^a-zA-Z0-9]'){ $classCount++ } # Special characters
    if($classCount -lt $MinClass){
        MsgFce "ERROR: Password for '$($FieldName)' does not meet complexity requirements! It must contain characters from at least $($MinClass) different classes (uppercase, lowercase, digits, special characters)" -Output error
        return $false
    }
    return $true
}

# IP Address Syntax Checker
Function Test-IsValidIPAddress {
    param([string]$IP)
    if([string]::IsNullOrWhiteSpace($IP)){ return $true }
    $ipObject = $null
    return [System.Net.IPAddress]::TryParse($IP, [ref]$ipObject)
}

# Validation and Configuration of vApp/OVF Properties via API
# Created by: William Lam - www.virtuallyghetto.com
Function Set-VMOvfProperty{
    param(
        [Parameter(Mandatory=$true)] $VM, 
        [Parameter(Mandatory=$true)] $ovfChanges 
    )

    $vappProperties = $VM.ExtensionData.Config.VAppConfig.Property
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.vAppConfig = New-Object VMware.Vim.VmConfigSpec
    $propertySpec = New-Object VMware.Vim.VAppPropertySpec[]($ovfChanges.count)

    foreach($vappProperty in $vappProperties){
        if($ovfChanges.ContainsKey($vappProperty.Id)){
            $tmp = New-Object VMware.Vim.VAppPropertySpec
            $tmp.Operation = "edit"
            $tmp.Info = New-Object VMware.Vim.VAppPropertyInfo
            $tmp.Info.Key = $vappProperty.Key
            $tmp.Info.value = $ovfChanges[$vappProperty.Id]
            $propertySpec+=($tmp)
        }
    }
    $spec.VAppConfig.Property = $propertySpec

    $task = $VM.ExtensionData.ReconfigVM_Task($spec)
    $task1 = Get-Task -Id ("Task-$($task.value)")
    $task1 | Wait-Task
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------
Clear-Host
Import-Module -Name VMware.VimAutomation.Core

# UAG configuration - merging of base and advanced settings
$UAG = @{}
$UAG_base.GetEnumerator() | ForEach-Object { $UAG[$_.Key] = $_.Value }
$UAG_advanced.GetEnumerator() | ForEach-Object { $UAG[$_.Key] = $_.Value }

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
MsgFce "SCRIPT START" -Output header -NoTimeStamp

# Validation of IP addresses from the config
foreach($ipKey in @("ip0", "ip1", "ip2", "defaultGateway", "DNS")){
    $ips = $UAG[$ipKey] -split " "
    foreach($ip in $ips){
        if(-not (Test-IsValidIPAddress -IP $ip)){
            MsgFce "ERROR: The value '$($ip)' in parameter '$($ipKey)' is not a valid IP address!" -Output error
            Exit
        }
    }
}

# vSphere: Connect to vCenter Server
$vc = $null
try{
    MsgFce "INFO: Connecting to vCenter Server '$($vSphere.VIServer)'..."
    if($vSphere.VIPassword -notlike ""){
        # Securely handle vCenter connection password
        $vSpherePwd = $vSphere.VIPassword
        if($vSpherePwd -is [string]){
            $vSpherePwd = ConvertTo-SecureString $vSpherePwd -AsPlainText -Force
        }
        $cred = New-Object System.Management.Automation.PSCredential ($vSphere.VIUsername, $vSpherePwd)
        $vc = Connect-VIServer -Server $vSphere.VIServer -Credential $cred -ErrorAction Stop
    } else{
        $cred = Get-Credential -UserName $vSphere.VIUsername -Message "Enter vCenter password for $($vSphere.VIUsername)"
        $vc = Connect-VIServer -Server $vSphere.VIServer -Credential $cred -ErrorAction Stop
    }
} catch{
    MsgFce "ERROR: Failed to connect to vCenter Server '$($vSphere.VIServer)'! Verification/Authentication failed" -Output error
    MsgFce "Error details: $($_.Exception.Message)" -Output error -NoTimeStamp
    MsgFce "Deployment process aborted" -Output error -NoTimeStamp -LinesAfter 1
    Exit
}

# Additional check to ensure vCenter connection
if(-not $vc -or -not $vc.IsConnected){
    MsgFce "ERROR: vCenter connection object is invalid or not active => Deployment process aborted" -Output error
    Exit
}
MsgFce "INFO: Successfully connected to vCenter Server"

# Retrieve passwords with immediate complexity validation and secure handling
foreach($passwType in @(@{name="root"; key="rootPassword"; minLen=$UAG.passwordPolicyMinLen; minClass=$UAG.passwordPolicyMinClass}, @{name="admin"; key="adminPassword"; minLen=$UAG.adminPasswordPolicyMinLen; minClass=4})){
    $valid = $false
    $passw = $UAG[$passwType.key]

    # Securely convert to SecureString if specified as a plain string in configuration hashtable
    if($passw -and $passw -is [string]){ $passw = ConvertTo-SecureString $passw -AsPlainText -Force }
    while(-not $valid){
        if(-not $passw){
            $cred = Get-Credential -UserName $passwType.name -Message "Enter a new secure password for the '$($passwType.name)' user:"
            $passw = $cred.Password # This returns a SecureString
        }
        $valid = Test-UAGPasswordStrength -Password $passw -FieldName $passwType.name -MinLength $passwType.minLen -MinClass $passwType.minClass
        if(-not $valid){
            $passw = $null # Reset variable to force re-prompt
        }
    }
    $UAG[$passwType.key] = $passw
}

# Retrieve PFX Certificate Password (if UagConfig is enabled and CertName contains PFX keyword)
$CertPfxPasswordPlain = $null
if($UAG.UagConfig -and ($UAG_ApiCfg.Params.Mode -in @("CfgConfigAndCert", "CfgCertOnly"))){
    $certName = $UAG_ApiCfg.Params.CertName
    if($certName -like "*PFX*" -or $certName -like "*.pfx*"){
        MsgFce "Enter password for PFX certificate '$($certName)':"
        $pfxSec = Read-Host -AsSecureString
        $CertPfxPasswordPlain = [System.Net.NetworkCredential]::new("", $pfxSec).Password
    }
}

# Resolve and verify OVA Template
if([string]::IsNullOrWhiteSpace($UAG.uagVersion)){
    # Automatic selection of latest version from $OVA_Repo
    $latestVersion = $OVA_Repo.Keys | Sort-Object { $_ } -ErrorAction SilentlyContinue | Select-Object -Last 1
    $UAG.uagVersion = $latestVersion
    MsgFce "INFO: UAG (latest) version automatically selected from '`$OVA_Repo': '$($UAG.uagVersion)'"
}

# Verify that the specified version exists in the repository hashtable
if(-not $OVA_Repo.ContainsKey($UAG.uagVersion)){
    MsgFce "ERROR: Target UAG version '$($UAG.uagVersion)' was not found in '`$OVA_Repo'" -Output error
    return
}

# Set $OVA path and verify if file exists on disk
$OVA = $OVA_Repo[$UAG.uagVersion]
if(-not (Test-Path $OVA)){
    MsgFce "ERROR: UAG template OVA file '$($OVA)' for version '$($UAG.uagVersion)' doesn't exist" -Output error
    return
}
MsgFce "INFO: Version of UAG used for deployment: '$($UAG.uagVersion)' ('$($OVA)')"

# Load OVA configuration details
$OvfCfg = Get-OvfConfiguration -Ovf $OVA
#$OvfCfg.psobject.Properties | ? Name -in 'Common','NetworkMapping' | % { $_.Value.psobject.Properties } | select Name, @{N='Description'; E={$_.Value.Description}} | ogv

# --- vApp/OVF Configuration ---
$OvfCfg.DeploymentOption.Value = $UAG.DeploymentOption
$OvfCfg.IpAssignment.IpProtocol.Value = $UAG.IpProtocol

# vApp NetworkMapping
foreach($cfg in @("Internet", "ManagementNetwork", "BackendNetwork")){
    $OvfCfg.NetworkMapping.$($cfg).Value = $UAG.$($cfg)
}

# vApp Common: Only basic parameters and the first NIC to avoid import failures
foreach($cfg in @("uagName", "defaultGateway", "DNS", "dnsSearch", "ipMode0", "ip0", "netmask0", "routes0", "eth0CustomConfig", "forwardrules")){
    $OvfCfg.Common.$($cfg).Value = $UAG.$($cfg)
}

# vApp Common: SSH
foreach($cfg in @("sshEnabled", "sshKeyAccessEnabled", "sshPasswordAccessEnabled", "sshInterface", "sshPort")){
    $OvfCfg.Common.$($cfg).Value = $UAG.$($cfg)
}

# vApp Common: Password Policy
foreach($cfg in @("adminPasswordPolicyFailedLockoutCount", "adminPasswordPolicyMinLen", "adminPasswordPolicyUnlockTime", "adminSessionIdleTimeoutMinutes", "adminMaxConcurrentSessions")){
    $OvfCfg.Common.$($cfg).Value = $UAG.$($cfg)
}
foreach($cfg in @("passwordPolicyFailedLockout", "passwordPolicyMinClass", "passwordPolicyMinLen", "passwordPolicyUnlockTime", "rootPasswordExpirationDays", "rootSessionIdleTimeoutSeconds")){
    $OvfCfg.Common.$($cfg).Value = $UAG.$($cfg)
}

# vApp Common: Others
foreach($cfg in @("ceipEnabled", "secureRandomSource", "osLoginUsername", "osMaxLoginLimit", "commandsFirstBoot", "commandsEveryBoot", "enabledAdvancedFeatures")){
    $OvfCfg.Common.$($cfg).Value = $UAG.$($cfg)
}

# vApp Common: Passwords (decrypting only at the moment of assignment to OvfConfiguration)
$OvfCfg.Common.rootPassword.Value = [System.Net.NetworkCredential]::new("", $UAG.rootPassword).Password
$OvfCfg.Common.adminPassword.Value = [System.Net.NetworkCredential]::new("", $UAG.adminPassword).Password

# SSH Login Banner Clean-up & Replacement
if($UAG.DeploymentOption -like "*onenic*"){
    $UAG.sshLoginBannerText = $UAG.sshLoginBannerText.Replace(", IP1: %ip1%", "").Replace(", IP2: %ip2%", "")
    $UAG.sshLoginBannerText = $UAG.sshLoginBannerText.Replace("https://%ip1%:", "https://%ip0%:")
    $UAG.sshLoginBannerText = $UAG.sshLoginBannerText.Replace("IP0:", "IP:")
} elseif($UAG.DeploymentOption -like "*twonic*"){
    $UAG.sshLoginBannerText = $UAG.sshLoginBannerText.Replace(", IP2: %ip2%", "")
}

# Replace tags in the banner with actual configuration values (safely skipping SecureStrings)
foreach($var in $($UAG.Keys)){
    $val = $UAG.$($var)
    if($val -and ($val -isnot [System.Security.SecureString]) -and ($val -notlike "")){
        $UAG.sshLoginBannerText = $UAG.sshLoginBannerText.Replace("%$($var)%", $val)
    }
}
# Convert real CRLF/LF newlines to literal '\n' strings for UAG/vSphere OVF parser
$UAG.sshLoginBannerText = ($UAG.sshLoginBannerText -replace "`r?`n", '\n').Trim()
$OvfCfg.Common.sshLoginBannerText.Value = $UAG.sshLoginBannerText

# Debug
#$OvfCfg.ToHashTable() | Format-Table
#break

# vSphere: Select a cluster host
if($vSphere.TargetHostName -like "*random*"){
    $TargetHost = Get-Cluster $vSphere.TargetCluster | Get-VMHost | Where-Object {$_.PowerState -eq "PoweredOn" -and $_.ConnectionState -eq "Connected"} | Get-Random
} else{
    $TargetHost = Get-Cluster $vSphere.TargetCluster | Get-VMHost | Where-Object {$_.Name -like $vSphere.TargetHostName -and $_.ConnectionState -eq "Connected"}
}

# vSphere: Select a datastore
if($vSphere.TargetDatastoreName -like "*random*"){
    $TargetDatastore = $TargetHost | Get-Datastore | Get-Random
} else{
    $TargetDatastore = $TargetHost | Get-Datastore | Where-Object {$_.Name -like $vSphere.TargetDatastoreName}
}

# vSphere: Resolve Target inventory folder if specified (supports single names and paths like 'Dir/SubDir' or 'Dir\SubDir')
$TargetFolder = $null
if($vSphere.TargetFolder -and $vSphere.TargetFolder -ne ""){
    $folderPath = $vSphere.TargetFolder -replace '\\', '/'
    $pathParts = $folderPath.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $currentLoc = $null
    foreach($part in $pathParts){
        if($null -eq $currentLoc){
            $currentLoc = Get-Folder -Name $part -ErrorAction SilentlyContinue | Select-Object -First 1
        } else{
            $currentLoc = Get-Folder -Name $part -Location $currentLoc -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if(-not $currentLoc){ break }
    }
    $TargetFolder = $currentLoc
    if($TargetFolder){
        MsgFce "INFO: Target folder '$($vSphere.TargetFolder)' resolved successfully"
    } else{
        MsgFce "WARN: Target folder '$($vSphere.TargetFolder)' was not found! VM will remain in default root folder" -Output warn
    }
}

# vSphere: Resolve Target Resource Pool if specified
$Location = $null
if($vSphere.TargetResourcePool -and $vSphere.TargetResourcePool -ne ""){
    $TargetRP = Get-Cluster $vSphere.TargetCluster | Get-ResourcePool -Name $vSphere.TargetResourcePool -ErrorAction SilentlyContinue
    if($TargetRP){
        $Location = $TargetRP
        MsgFce "INFO: Target Resource Pool '$($TargetRP.Name)' resolved successfully"
    } else{
        MsgFce "WARN: Resource Pool '$($vSphere.TargetResourcePool)' was not found in Cluster '$($vSphere.TargetCluster)' => Defaulting to host placement" -Output warn
    }
}

# vSphere: Detection of Existing VM
$vmExist = Get-VM -Name $UAG.uagName -ErrorAction SilentlyContinue
if($vmExist){  
    MsgFce "ERROR: UAG virtual machine '$($UAG.uagName)' already exists in vCenter => Deployment aborted!" -Output error
    Exit
}

# --- vSphere: Deploy/Import the UAG Appliance ---
MsgFce "INFO: Starting UAG deployment for '$($UAG.uagName)' ($($UAG.DeploymentOption), IP0: $($UAG.ip0))..." -Output verbose -LinesBefore 1
# Import the UAG VM based on whether a Resource Pool (Location) was specified and resolved
if($Location){
    Import-VApp -Source $OVA -OvfConfiguration $OvfCfg -Name $UAG.uagName -VMHost $TargetHost -Datastore $TargetDatastore -Location $Location -DiskStorageFormat Thin -Force
} else{
    Import-VApp -Source $OVA -OvfConfiguration $OvfCfg -Name $UAG.uagName -VMHost $TargetHost -Datastore $TargetDatastore -DiskStorageFormat Thin -Force
}
# Move VM to the specified folder if resolved
if($TargetFolder){
    MsgFce "INFO: Moving deployed VM '$($UAG.uagName)' to folder '$($TargetFolder.Name)'..."
    Move-VM -VM $UAG.uagName -InventoryLocation $TargetFolder -Confirm:$false | Out-Null
}

# vSphere: Update VM vApp/OVF properties (retrieve user-configurable machine parameters and apply updates from $UAG config)
$vmUAG = Get-VM -Name $UAG.uagName -ErrorAction SilentlyContinue
if($vmUAG.PowerState -eq "PoweredOff"){
    $vAppCfg = ($vmUAG.ExtensionData.Config.VAppConfig.Property) | Where-Object { $_.UserConfigurable -eq $true }
    if($vAppCfg.Count){
        $updateArr = @{}
        foreach($cfg in $vAppCfg){
            if(($cfg.Type -notlike "boolean") -and ($UAG[$cfg.Id] -notlike "") -and ($UAG[$cfg.Id] -ne $cfg.Value)){
                # Safely extract plain text from SecureString if updating OVF properties
                $valueToAssign = $UAG[$cfg.Id]
                if($valueToAssign -is [System.Security.SecureString]){
                    $valueToAssign = [System.Net.NetworkCredential]::new("", $valueToAssign).Password
                }
                $updateArr.Add($cfg.Id, $valueToAssign)
            }
        }
        if($updateArr.Count){
            MsgFce "INFO: Writing additional OVF properties for network adapters..."
            Set-VMOvfProperty -VM $vmUAG -ovfChanges $updateArr
        } else{
            MsgFce "INFO: All OVF properties are already up-to-date"
        }
    }
} else{
    MsgFce "WARN: UAG VM '$($UAG.uagName)' must be powered off to apply vApp configuration changes" -Output warn
}

# vSphere: Set VM Notes / Annotation
if($UAG.vmNotes -and $UAG.vmNotes -ne ""){
    $vmNotes = $UAG.vmNotes
    $vmNotes = $vmNotes.Replace("%uagName%", $UAG.uagName)
    $vmNotes = $vmNotes.Replace("%uagVersion%", $UAG.uagVersion)
    $vmNotes = $vmNotes.Replace("%date%", (Get-Date -Format "yyyy-MM-dd"))

    MsgFce "INFO: Updating vSphere VM Notes for '$($UAG.uagName)'..."
    Set-VM -VM $UAG.uagName -Notes $vmNotes -Confirm:$false | Out-Null
}

# --- Power-On the UAG VM and execute API Configuration ---
if($UAG.UagPowerOn){
    MsgFce "INFO: Powering on UAG VM '$($UAG.uagName)'..." -LinesBefore 1
    Start-VM -VM $UAG.uagName -Confirm:$false | Out-Null

    # Auto-trigger API Management script if configUAG is enabled
    if($UAG.UagConfig){
        if(-not [System.IO.Path]::IsPathRooted($UAG_ApiCfg.ScriptName)){ $UAG_ApiCfg.ScriptName = Join-Path $PSScriptRoot $UAG_ApiCfg.ScriptName }

        if(Test-Path $UAG_ApiCfg.ScriptName){
            MsgFce "INFO: Triggering automatic UAG API configuration via '$($UAG_ApiCfg.ScriptName)'..." -LinesAfter 1
            # Pre-create DPAPI credential file for target UAG Admin using template from $UAG_ApiCfg (if defined)
            if(-not [string]::IsNullOrWhiteSpace($UAG_ApiCfg.SecCredUAG)){
                $secCredFile = Join-Path $PSScriptRoot ($UAG_ApiCfg.SecCredUAG -f $UAG.uagName)
                $UAG.adminPassword | ConvertFrom-SecureString | Out-File $secCredFile -ErrorAction SilentlyContinue
            }
            
            # API Cfg Script Params
            $apiCfgParams = if($UAG_ApiCfg.Params -is [hashtable]){ $UAG_ApiCfg.Params.Clone() } else{ @{} }
            $apiCfgParams["TargetUAG"] = $UAG.uagName
            # Attach PFX password if specified
            if($CertPfxPasswordPlain){ $apiCfgParams["CertPfxPassword"] = $CertPfxPasswordPlain }

            # Execute API Management script
            & $UAG_ApiCfg.ScriptName @apiCfgParams

            # Wipe PFX password from memory
            $CertPfxPasswordPlain = $null
        } else{
            MsgFce "ERROR: API Management script '$($UAG_ApiCfg.ScriptName)' was not found!" -Output error
        }
    }
} elseif($UAG.UagConfig){
    MsgFce "WARN: 'UagConfig' is enabled, but 'UagPowerOn' is false => Cannot configure UAG API while VM is powered off!" -Output warn
}

# vSphere: Disconnect from vCenter Server
if($vc -and $vc.IsConnected){ Disconnect-VIServer -Server $vc -Confirm:$false | Out-Null }

MsgFce "SUCCESS: UAG deployment finished successfully!" -Output success
MsgFce "SCRIPT FINISH" -Output header -NoTimeStamp
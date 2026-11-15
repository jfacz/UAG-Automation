<#
.SYNOPSIS
   Automated deployment script for Omnissa Unified Access Gateway (UAG) via PowerCLI.

.DESCRIPTION
   Deploys Omnissa UAG OVA appliances into VMware vSphere using PowerCLI with complete automation.
   Handles OVF properties, vSphere VM Notes, and triggers automated UAG configuration via REST API (UAG_Config.ps1).

.EXAMPLE
   # Menu with all cfg_UAG_Deploy_*.ps1 files found in the script folder
   .\UAG_Deploy.ps1

.EXAMPLE
   # Deployment of the appliance defined in cfg_UAG_Deploy_VDI-UAG01.ps1 (short name, file name or full path)
   .\UAG_Deploy.ps1 -DeployCfg VDI-UAG01

.LINK
   https://github.com/jfacz/UAG-Automation

.NOTES
   Version:        2610.0
   Author:         Jan Fara
   Last Update:    2026-10-31

   [v2610.0 - 20261031] New Common UAG configuration in separate file 'cfg_UAG_Deploy.ps1'
                        New Configuration of each UAG in its own file 'cfg_UAG_Deploy_<UagName>.ps1'
                        New separated file 'fce_UAG_Automation.ps1' with shared functions
                        Better Pre-flight check before deployment and configuration (incl. check of unfilled '<...>' placeholders)
                        Error handling: any failure ends the deployment (try/catch/finally), vCenter is always disconnected
                        Bug fixes and stability improvements
   [v2609.0 - 20260916] Initial release
#>

# ==============================================================================
# Script Parameters
# ==============================================================================
param (
    [Parameter(Mandatory=$false, HelpMessage="Appliance configuration: short UAG name, file name or full path of cfg_UAG_Deploy_<UagName>.ps1 (if omitted, the script offers a menu)")]
    [string] $DeployCfg
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
  ScriptName = "UAG Deployment"
 # Common configuration file (optional) - defaults for all appliances
  CommonCfg  = "cfg_UAG_Deploy.ps1"
 # Appliance configuration file mask ({0} = UAG name or '*')
  UagCfgMask = "cfg_UAG_Deploy_{0}.ps1"
}
# ==============================================================================

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Loads a configuration file in an isolated (function) scope and returns hashtables defined by it
# (variables of the main script are not visible/overwritten: only variables defined by the file itself - Scope Local - are returned)
Function Import-DeployCfg {
    param (
        [Parameter(Mandatory=$true)] [string] $CfgFilePath
    )

    . $CfgFilePath
    $result = @{}
    foreach($cfgVarName in @("UAG_OVA_Repo", "CFG_vSphere", "CFG_UAG")){
        $cfgVarValue = Get-Variable -Name $cfgVarName -Scope Local -ValueOnly -ErrorAction SilentlyContinue
        if($cfgVarValue -is [hashtable]){ $result[$cfgVarName] = $cfgVarValue }
    }
    return $result
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
        MsgFce "WARN: Password for '$($FieldName)' must have at least $($MinLength) characters!" -Output warn
        return $false
    }
    $classCount = 0
    if($plainPassword -match '[0-9]'){ $classCount++ } # Digits
    if($plainPassword -match '[A-Z]'){ $classCount++ } # Uppercase letters
    if($plainPassword -match '[a-z]'){ $classCount++ } # Lowercase letters
    if($plainPassword -match '[^a-zA-Z0-9]'){ $classCount++ } # Special characters
    if($classCount -lt $MinClass){
        MsgFce "WARN: Password for '$($FieldName)' does not meet complexity requirements! It must contain characters from at least $($MinClass) different classes (uppercase, lowercase, digits, special characters)" -Output warn
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
    $task1 | Wait-Task | Out-Null
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------
Clear-Host
$script:HadError = $false   # Any error occurred => exit code 1
$vc = $null
# Any PowerCLI / cmdlet error ends the deployment (handled by catch below); calls where an error is expected use -ErrorAction SilentlyContinue
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
MsgFce "SCRIPT START" -Output header -NoTimeStamp

try{
    # --- Check and load VMware PowerCLI module ---
    if(-not ((Get-Module -Name "VMware.VimAutomation.Core") -or (Get-Module -ListAvailable -Name "VMware.VimAutomation.Core"))){
        throw "ERROR: Required module 'VMware.VimAutomation.Core' (VMware PowerCLI) not found!"
    }
    MsgFce "INFO: Loading VMware PowerCLI module (can take a while)..." -Output note
    Import-Module -Name VMware.VimAutomation.Core

    # --- Select appliance configuration file ---
    $cfgFile = $null
    if($DeployCfg){
        # Short UAG name, file name in script folder, or full path
        foreach($candidate in @($DeployCfg, (Join-Path $PSScriptRoot $DeployCfg), (Join-Path $PSScriptRoot ($VAR.UagCfgMask -f $DeployCfg)))){
            if(Test-Path $candidate -PathType Leaf){ $cfgFile = (Resolve-Path $candidate).Path; break }
        }
        if(-not $cfgFile){ throw "ERROR: Appliance configuration '$($DeployCfg)' was not found (expected e.g. '$($VAR.UagCfgMask -f $DeployCfg)' in '$($PSScriptRoot)')!" }
    } else{
        $cfgFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter ($VAR.UagCfgMask -f "*") -File | Sort-Object Name)
        if($cfgFiles.Count -eq 0){ throw "ERROR: No appliance configuration file '$($VAR.UagCfgMask -f '*')' was found in '$($PSScriptRoot)'!" }
        if($cfgFiles.Count -eq 1){
            $cfgFile = $cfgFiles[0].FullName
        } else{
            $mTitle = "Select UAG appliance configuration to deploy"
            $mOpts = @("Exit") + @($cfgFiles | ForEach-Object { $_.Name })
            $selName = MenuSimple -MenuItems $mOpts -Title $mTitle -StartFrom 0
            if($selName -like "Exit"){
                MsgFce "WARN: Terminated by user (exit)" -Output warn -NoTimeStamp
                return   # finally block below ends the script (exit code 0)
            }
            $cfgFile = ($cfgFiles | Where-Object { $_.Name -eq $selName } | Select-Object -First 1).FullName
        }
    }
    MsgFce "INFO: Appliance configuration file: '$($cfgFile)'" -LinesBefore 1

    # --- Load configuration for deployment ---
    # Common cfg import
    $cfgCommon = @{}
    $commonCfg = Join-Path $PSScriptRoot $VAR.CommonCfg
    if(Test-Path $commonCfg -PathType Leaf){
        $cfgCommon = Import-DeployCfg -CfgFilePath $commonCfg
        MsgFce "INFO: Common configuration file: '$($commonCfg)'"
    } else{
        MsgFce "INFO: Common configuration file '$($VAR.CommonCfg)' not found => only the appliance configuration is used" -Output note
    }
    # UAG cfg import
    $cfgUnit = Import-DeployCfg -CfgFilePath $cfgFile

    foreach($cfgName in @("UAG_OVA_Repo", "CFG_vSphere", "CFG_UAG")){
        $merged = @{}
        foreach($src in @($cfgCommon, $cfgUnit)){
            if($src.ContainsKey($cfgName)){ $merged = Merge-Hashtables -Base $merged -Override $src[$cfgName] }
        }
        Set-Variable -Name $cfgName -Value $merged -Scope Script
    }
    if($CFG_UAG.Count -eq 0 -or [string]::IsNullOrWhiteSpace($CFG_UAG.uagName)){ throw "ERROR: '`$CFG_UAG' with 'uagName' is missing in '$($cfgFile)'!" }
    if($UAG_OVA_Repo.Count -eq 0){ throw "ERROR: '`$UAG_OVA_Repo' is not defined in the configuration!" }
    if($CFG_vSphere.Count -eq 0){ throw "ERROR: '`$CFG_vSphere' is not defined in the configuration!" }

    # UAG configuration
    $UAG = @{}
    $CFG_UAG.GetEnumerator() | ForEach-Object { $UAG[$_.Key] = $_.Value }
    # Check for unfilled placeholders '<...>' (values from the common cfg that were not overridden)
    Confirm-NoPlaceholders -Data $UAG -Path "CFG_UAG" -Context "UAG configuration (override it in '$(Split-Path $cfgFile -Leaf)')"
    Confirm-NoPlaceholders -Data $CFG_vSphere -Path "CFG_vSphere" -Context "vSphere configuration"

    MsgFce "INFO: UAG appliance: '$($UAG.uagName)' ($($UAG.DeploymentOption), IP0: $($UAG.ip0))"

    # --- Validation of IP addresses and NIC settings from the config ---
    foreach($ipKey in @("ip0", "ip1", "ip2", "defaultGateway", "DNS")){
        foreach($ip in ($UAG[$ipKey] -split " ")){
            if(-not (Test-IsValidIPAddress -IP $ip)){ throw "ERROR: The value '$($ip)' in parameter '$($ipKey)' is not a valid IP address!" }
        }
    }
    $nicCount = if($UAG.DeploymentOption -like "*threenic*"){ 3 } elseif($UAG.DeploymentOption -like "*twonic*"){ 2 } else{ 1 }
    foreach($n in 0..($nicCount - 1)){
        if($UAG["ipMode$($n)"] -like "STATIC*"){
            if([string]::IsNullOrWhiteSpace($UAG["ip$($n)"]) -or [string]::IsNullOrWhiteSpace($UAG["netmask$($n)"])){
                throw "ERROR: Deployment option '$($UAG.DeploymentOption)' with static IP requires 'ip$($n)' and 'netmask$($n)' (NIC $($n + 1))!"
            }
        }
    }
    # Management IP = address where the UAG REST API (port 9443) is reachable: eth0 for 'onenic', eth1 for 'twonic'/'threenic'
    $mgmtIP = if($nicCount -gt 1){ $UAG.ip1 } else{ $UAG.ip0 }

    # --- Resolve and verify OVA Template ---
    if([string]::IsNullOrWhiteSpace($UAG.uagVersion)){
        # Automatic selection of latest version from $UAG_OVA_Repo
        $UAG.uagVersion = $UAG_OVA_Repo.Keys | Sort-Object | Select-Object -Last 1
        MsgFce "INFO: UAG (latest) version automatically selected from '`$UAG_OVA_Repo': '$($UAG.uagVersion)'"
    }
    if(-not $UAG_OVA_Repo.ContainsKey($UAG.uagVersion)){ throw "ERROR: Target UAG version '$($UAG.uagVersion)' was not found in '`$UAG_OVA_Repo'" }
    $OVA = $UAG_OVA_Repo[$UAG.uagVersion]
    if(-not (Test-Path $OVA -PathType Leaf)){ throw "ERROR: UAG template OVA file '$($OVA)' for version '$($UAG.uagVersion)' doesn't exist" }
    MsgFce "INFO: Version of UAG used for deployment: '$($UAG.uagVersion)' ('$($OVA)')"

    # --- Pre-flight check of the post-deployment UAG REST API Configuration (before anything is created in vSphere) ---
    # UAG_Config.ps1 validates its own configuration (UAG inventory, certificate, referenced files, secrets) without contacting the UAG
    $cfgScript = $null
    if($UAG.UagAutoConfig -and $UAG.UagPowerOn){
        if($UAG.UagRestApiCfg.Count -eq 0 -or [string]::IsNullOrWhiteSpace($UAG.UagRestApiCfg.ScriptName)){ throw "ERROR: 'UagAutoConfig' is enabled, but 'UagRestApiCfg.ScriptName' is not defined in the configuration!" }
        $cfgScript = $UAG.UagRestApiCfg.ScriptName
        if(-not [System.IO.Path]::IsPathRooted($cfgScript)){ $cfgScript = Join-Path $PSScriptRoot $cfgScript }
        if(-not (Test-Path $cfgScript -PathType Leaf)){ throw "ERROR: UAG Config script '$($cfgScript)' was not found!" }

        MsgFce "INFO: Validating the UAG API configuration via '$([System.IO.Path]::GetFileName($cfgScript))' -ValidateOnly..."
        $validateParams = if($UAG.UagRestApiCfg.Params -is [hashtable]){ $UAG.UagRestApiCfg.Params.Clone() } else{ @{} }
        $validateParams["TargetUAG"]    = $UAG.uagName
        $validateParams["ValidateOnly"] = $true
        $validateParams["ExpectedIP"]   = $mgmtIP   # management address = where the UAG REST API (port 9443) will be available
        $global:LASTEXITCODE = 0
        $ErrorActionPreference = "Continue"
        & $cfgScript @validateParams
        $validateExitCode = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if($validateExitCode -ne 0){ throw "ERROR: Validation of the UAG API configuration failed (exit code $($validateExitCode)) => deployment aborted before the VM was created. See the output above." }
    }

    # --- vSphere: Connect to vCenter Server ---
    MsgFce "INFO: Connecting to vCenter Server '$($CFG_vSphere.VIServer)'..."
    try{
        if($CFG_vSphere.VIPassword -notlike ""){
            $vSpherePwd = ConvertTo-SecureString $CFG_vSphere.VIPassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ($CFG_vSphere.VIUsername, $vSpherePwd)
        } else{
            $cred = Get-Credential -UserName $CFG_vSphere.VIUsername -Message "Enter vCenter password for $($CFG_vSphere.VIUsername)"
        }
        $vc = Connect-VIServer -Server $CFG_vSphere.VIServer -Credential $cred
    } catch{
        throw "ERROR: Failed to connect to vCenter Server '$($CFG_vSphere.VIServer)'! $($_.Exception.Message)"
    }
    if(-not $vc -or -not $vc.IsConnected){ throw "ERROR: vCenter connection object is invalid or not active" }
    MsgFce "INFO: Successfully connected to vCenter Server"

    # --- Retrieve passwords with immediate complexity validation and secure handling ---
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

    # --- vApp/OVF Configuration ---
    $OvfCfg = Get-OvfConfiguration -Ovf $OVA
    #$OvfCfg.psobject.Properties | ? Name -in 'Common','NetworkMapping' | % { $_.Value.psobject.Properties } | select Name, @{N='Description'; E={$_.Value.Description}} | ogv

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
    foreach($var in @($UAG.Keys)){
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

    # --- vSphere: Select a cluster host ---
    $clusterHosts = @(Get-Cluster $CFG_vSphere.TargetCluster | Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" })
    $TargetHost = if($CFG_vSphere.TargetHostName -like "*random*"){
        $clusterHosts | Where-Object { $_.PowerState -eq "PoweredOn" } | Get-Random
    } else{
        $clusterHosts | Where-Object { $_.Name -like $CFG_vSphere.TargetHostName } | Select-Object -First 1
    }
    if(-not $TargetHost){ throw "ERROR: No suitable connected host ('$($CFG_vSphere.TargetHostName)') was found in cluster '$($CFG_vSphere.TargetCluster)'!" }

    # --- vSphere: Select a datastore ---
    $TargetDatastore = if($CFG_vSphere.TargetDatastoreName -like "*random*"){
        $TargetHost | Get-Datastore | Get-Random
    } else{
        $TargetHost | Get-Datastore | Where-Object { $_.Name -like $CFG_vSphere.TargetDatastoreName } | Select-Object -First 1
    }
    if(-not $TargetDatastore){ throw "ERROR: Datastore '$($CFG_vSphere.TargetDatastoreName)' was not found on host '$($TargetHost.Name)'!" }
    MsgFce "INFO: Target host: '$($TargetHost.Name)', datastore: '$($TargetDatastore.Name)'"

    # --- vSphere: Resolve Target inventory folder if specified (supports single names and paths like 'Dir/SubDir' or 'Dir\SubDir') ---
    $TargetFolder = $null
    if($CFG_vSphere.TargetFolder -and $CFG_vSphere.TargetFolder -ne ""){
        $folderPath = $CFG_vSphere.TargetFolder -replace '\\', '/'
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
            MsgFce "INFO: Target folder '$($CFG_vSphere.TargetFolder)' resolved successfully"
        } else{
            MsgFce "WARN: Target folder '$($CFG_vSphere.TargetFolder)' was not found! VM will remain in default root folder" -Output warn
        }
    }

    # --- vSphere: Resolve Target Resource Pool if specified ---
    $Location = $null
    if($CFG_vSphere.TargetResourcePool -and $CFG_vSphere.TargetResourcePool -ne ""){
        $TargetRP = Get-Cluster $CFG_vSphere.TargetCluster | Get-ResourcePool -Name $CFG_vSphere.TargetResourcePool -ErrorAction SilentlyContinue
        if($TargetRP){
            $Location = $TargetRP
            MsgFce "INFO: Target Resource Pool '$($TargetRP.Name)' resolved successfully"
        } else{
            MsgFce "WARN: Resource Pool '$($CFG_vSphere.TargetResourcePool)' was not found in Cluster '$($CFG_vSphere.TargetCluster)' => Defaulting to host placement" -Output warn
        }
    }

    # --- vSphere: Detection of Existing VM ---
    if(Get-VM -Name $UAG.uagName -ErrorAction SilentlyContinue){ throw "ERROR: UAG virtual machine '$($UAG.uagName)' already exists in vCenter => Deployment aborted!" }

    # --- vSphere: Deploy/Import the UAG Appliance ---
    MsgFce "INFO: Starting UAG deployment for '$($UAG.uagName)' ($($UAG.DeploymentOption), IP0: $($UAG.ip0))..." -Output verbose -LinesBefore 1
    $importParams = @{
        Source            = $OVA
        OvfConfiguration  = $OvfCfg
        Name              = $UAG.uagName
        VMHost            = $TargetHost
        Datastore         = $TargetDatastore
        DiskStorageFormat = "Thin"
        Force             = $true
    }
    if($Location){ $importParams["Location"] = $Location }
    Import-VApp @importParams | Out-Null

    # Move VM to the specified folder if resolved
    if($TargetFolder){
        MsgFce "INFO: Moving deployed VM '$($UAG.uagName)' to folder '$($TargetFolder.Name)'..."
        Move-VM -VM $UAG.uagName -InventoryLocation $TargetFolder -Confirm:$false | Out-Null
    }

    # --- vSphere: Update VM vApp/OVF properties (retrieve user-configurable machine parameters and apply updates from $UAG config) ---
    $vmUAG = Get-VM -Name $UAG.uagName
    if($vmUAG.PowerState -eq "PoweredOff"){
        $vAppCfg = ($vmUAG.ExtensionData.Config.VAppConfig.Property) | Where-Object { $_.UserConfigurable -eq $true }
        if($vAppCfg.Count){
            $updateArr = @{}
            foreach($cfg in $vAppCfg){
                # Only properties defined in the configuration (others keep their OVA defaults)
                if(($cfg.Type -notlike "boolean") -and $UAG.ContainsKey($cfg.Id) -and ($null -ne $UAG[$cfg.Id]) -and ($UAG[$cfg.Id] -notlike "") -and ($UAG[$cfg.Id] -ne $cfg.Value)){
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

    # --- vSphere: Set VM Notes / Annotation ---
    if($CFG_vSphere.vmNotes -and $CFG_vSphere.vmNotes -ne ""){
        $vmNotes = $CFG_vSphere.vmNotes
        $vmNotes = $vmNotes.Replace("%uagName%", $UAG.uagName)
        $vmNotes = $vmNotes.Replace("%uagVersion%", $UAG.uagVersion)
        $vmNotes = $vmNotes.Replace("%date%", (Get-Date -Format "yyyy-MM-dd"))

        MsgFce "INFO: Updating vSphere VM Notes for '$($UAG.uagName)'..."
        Set-VM -VM $UAG.uagName -Notes $vmNotes -Confirm:$false | Out-Null
    }

    # --- Power-On the UAG VM and execute UAG Configuration via REST API ---
    if($UAG.UagPowerOn){
        MsgFce "INFO: Powering on UAG VM '$($UAG.uagName)'..." -LinesBefore 1
        Start-VM -VM $UAG.uagName -Confirm:$false | Out-Null

        # Auto-trigger UAG Config script if UagAutoConfig is enabled
        if($UAG.UagAutoConfig){
            MsgFce "INFO: Triggering automatic UAG API configuration via '$($cfgScript)'..." -LinesAfter 1

            # UAG Cfg Script Params (admin password of the new UAG is passed as SecureString - the script uses it and stores it via DPAPI itself)
            $apiCfgParams = if($UAG.UagRestApiCfg.Params -is [hashtable]){ $UAG.UagRestApiCfg.Params.Clone() } else{ @{} }
            $apiCfgParams["TargetUAG"]     = $UAG.uagName
            $apiCfgParams["AdminPassword"] = $UAG.adminPassword

            # Execute UAG Cfg script (its own error handling is used => 'Continue'; result is evaluated from the exit code)
            $global:LASTEXITCODE = 0
            $ErrorActionPreference = "Continue"
            & $cfgScript @apiCfgParams
            $apiExitCode = $LASTEXITCODE
            $ErrorActionPreference = "Stop"

            if($apiExitCode -ne 0){
                MsgFce "ERROR: UAG '$($UAG.uagName)' was deployed, but its API configuration finished with errors (exit code $($apiExitCode)). See the output above." -Output error -LinesBefore 1
            }
        }
    } elseif($UAG.UagAutoConfig){
        MsgFce "WARN: 'UagAutoConfig' is enabled, but 'UagPowerOn' is false => Cannot configure UAG Config script while VM is powered off!" -Output warn
    }

    if($script:HadError){
        MsgFce "WARN: UAG '$($UAG.uagName)' deployment finished WITH ERRORS!" -Output warn -LinesBefore 1
    } else{
        MsgFce "SUCCESS: UAG '$($UAG.uagName)' deployment finished successfully!" -Output success -LinesBefore 1
    }
} catch{
    $errMsg = $_.Exception.Message
    if($errMsg -notmatch '^ERROR:'){ $errMsg = "ERROR: $($errMsg)" }
    MsgFce $errMsg -Output error -LinesBefore 1
    MsgFce "Deployment process aborted" -Output error -NoTimeStamp
} finally {
    # --- Cleanup of Sensitive Data ---
    $apiCfgParams = $null
    $validateParams = $null
    $OvfCfg = $null
    $cred = $null
    $passw = $null
    $vSpherePwd = $null
    $UAG = $null
    [GC]::Collect()

    # --- vSphere: Disconnect from vCenter Server (always) ---
    if($vc -and $vc.IsConnected){ Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }

    MsgFce "SCRIPT FINISH" -Output header -NoTimeStamp

    # --- Exit code (0 = OK, 1 = any error) ---
    # Must be in 'finally': 'return'/'throw' in 'try' would otherwise skip any code placed after the block
    if($script:HadError){ exit 1 } else{ exit 0 }
}

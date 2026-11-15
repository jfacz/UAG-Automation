<#
.SYNOPSIS
   Deployment configuration of one UAG appliance for UAG_Deploy.ps1 - UAG with password authentication.

.DESCRIPTION
   Defines this appliance (name, size, network, power-on, post-deployment configuration).
   It overrides the common cfg_UAG_Deploy.ps1 (only the changed keys are needed).

   Values in the form <...> are placeholders - the script aborts until they are replaced with real values (or removed).

.LINK
   https://github.com/jfacz/UAG-Automation
#>

$CFG_UAG = @{
    # --- UAG Deployment ---
    # UAG / VM Name (must match the Name in the inventory of cfg_UAG.ps1)
    uagName        = "VDI-UAG01"
    # UAG target version key from $UAG_OVA_Repo or leave empty for latest
    uagVersion     = ""
    # UAG Post-Deployment Automatic Power-On
    UagPowerOn     = $true
    # UAG Post-Deployment Automatic Configuration by REST API script (requires UagPowerOn = $true)
    UagAutoConfig  = $true
    UagRestApiCfg  = @{
        ScriptName = "UAG_Config.ps1" # Relative to script folder or full path
        Params = @{
            UagCfg   = "cfg_UAG.ps1"
            Mode     = "CfgConfigAndCert" # CfgConfigOnly | CfgCertOnly | CfgConfigAndCert
            CertName = "vdi.company.com [PFX]"
        }
    }

    # --- UAG Base Settings ---
    # Deployment Size: "onenic", "twonic", "threenic", "onenic-large", "twonic-large", "threenic-large", "onenic-XL", "twonic-XL", "threenic-XL"
    DeploymentOption = "onenic"
    # root & admin password (if empty, the script will securely prompt and check complexity)
    rootPassword  = ""
    adminPassword = ""
    # Network Portgroup Mapping (Internet = eth0, ManagementNetwork = eth1, BackendNetwork = eth2)
    Internet          = "<PortGroup>"
    ManagementNetwork = "<PortGroup>"
    BackendNetwork    = "<PortGroup>"
    # Network Settings
    IpProtocol     = "IPv4" # IPv4 | IPv6
    defaultGateway = "<10.0.10.1>"
    DNS            = "<10.0.1.10 10.0.1.11>" # Space separated
    dnsSearch      = "company.com"
    # Network Settings NIC1 [eth0]
    ipMode0        = "STATICV4"
    ip0            = "<10.0.10.11>"
    netmask0       = "<255.255.255.0>"
    routes0        = ""
}
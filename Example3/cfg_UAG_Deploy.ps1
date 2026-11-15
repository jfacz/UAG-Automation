<#
.SYNOPSIS
   Common deployment configuration (defaults for all appliances) for UAG_Deploy.ps1

.DESCRIPTION
   Defines settings shared by all UAG appliances: OVA repository ($UAG_OVA_Repo), vSphere ($CFG_vSphere) and UAG defaults ($CFG_UAG).
   Each appliance file (cfg_UAG_Deploy_<UagName>.ps1) can override any of these (only the changed keys are needed).

   Values in the form <...> are placeholders - the script aborts until they are replaced with real values (or removed).

.LINK
   https://github.com/jfacz/UAG-Automation
#>

# --- UAG OVA Templates Repository ---
$UAG_OVA_Repo = @{
    "2606" = "C:\Install\UAG\euc-unified-access-gateway-26.06.0.0-32063449787_OVF10.ova"
    "2609" = "C:\Install\UAG\euc-unified-access-gateway-26.09.0.0-40481840070_OVF10.ova"
}

# --- vSphere / vCenter Configuration ---
$CFG_vSphere = @{
    # vCenter Server FQDN
    VIServer            = "<vcenter.company.com>"
    # vCenter User Account
    VIUsername          = "<username@vsphere.local>"
    # vCenter User Password (if empty, the script will securely prompt)
    VIPassword          = ""
    # Target vSphere Cluster
    TargetCluster       = "<ClusterName>"
    # Target vSphere Host Name or "*random*" for a random powered-on host
    TargetHostName      = "*random*"
    # Target Datastore Name or "*random*"
    TargetDatastoreName = "<DatastoreName>"
    # Optional: Target vSphere Inventory VM Folder path (leave empty if not used)
    TargetFolder        = "<vSphereInventoryFolder>"
    # Optional: Target vSphere Resource Pool (leave empty if not used)
    TargetResourcePool  = ""
    # vSphere VM Notes (multi-line using `n) - supports variables %date% [yyyy-MM-dd] and %uagName%, %uagVersion% from $CFG_UAG
    vmNotes             = "Omnissa EUC Unified Access Gateway`nUAG Name: %uagName%`nUAG Version: %uagVersion%`nDate of deploy: %date%"
}

# --- UAG Deployment/Configuration Settings ---
$CFG_UAG = @{
  # --- UAG Deployment ---
    # UAG / VM Name (must match the Name in the inventory of cfg_UAG.ps1)
    uagName        = "<UagName>"
    # UAG target version key from $UAG_OVA_Repo or leave empty for latest
    uagVersion     = ""
    # UAG Post-Deployment Automatic Power-On
    UagPowerOn     = $false
    # UAG Post-Deployment Automatic Configuration by REST API script (requires UagPowerOn = $true)
    UagAutoConfig  = $true
    UagRestApiCfg  = @{
        ScriptName = "UAG_Config.ps1" # Relative to script folder or full path
        Params = @{
            UagCfg = "cfg_UAG.ps1"
            Mode   = "CfgConfigAndCert" # CfgConfigOnly | CfgCertOnly | CfgConfigAndCert
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
    dnsSearch      = "<company.com>"
    # NIC1 [eth0]
    ipMode0        = "STATICV4"
    ip0            = "<10.0.10.11>"
    netmask0       = "<255.255.255.0>"
    routes0        = ""
    # NIC2 [eth1] (if twonic/threenic used)
    ipMode1        = "STATICV4"
    ip1            = ""
    netmask1       = ""
    routes1        = ""
    # NIC3 [eth2] (if threenic used)
    ipMode2        = "STATICV4"
    ip2            = ""
    netmask2       = ""
    routes2        = ""

  # --- UAG Advanced Settings ---
    # Customer Experience Improvement Program
    ceipEnabled      = $false
    # Network Advanced Settings
    forwardrules     = ""
    eth0CustomConfig = ""
    eth1CustomConfig = ""
    eth2CustomConfig = ""
    # SSH Settings
    sshEnabled               = $false   # default: false
    sshKeyAccessEnabled      = $false   # default: false
    sshPasswordAccessEnabled = $true    # default: true
    sshInterface             = ""       # string["", "eth0", "eth1", "eth2"]. If not provided (empty), SSH will be enabled on all interface
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
    secureRandomSource      = "Default"          # When set to Default, '/dev/random' is used in Non-FIPS mode and '/dev/urandom' is used in FIPS mode
    osLoginUsername         = ""                 # Custom Admin name (disables root if selected)
    osMaxLoginLimit         = ""                 # Maximum limit for concurrent sudo user logins; default 10
    commandsFirstBoot       = ""
    commandsEveryBoot       = ""
    enabledAdvancedFeatures = ""                 # Comma separated list of advanced features
}
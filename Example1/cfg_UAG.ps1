<#
.SYNOPSIS
   Configuration and inventory of Omnissa Unified Access Gateway (UAG) appliances for UAG_Config.ps1

.DESCRIPTION
   Defines UAG appliance inventory ($UAG), SSL certificates ($CERTS), global default settings ($UAG_CFG["ALL"])
   and appliance-specific overrides ($UAG_CFG["<Appliance_Name>"]).

   Values in the form <...> are placeholders - the script aborts until they are replaced with real values (or removed).

.NOTES
   One UAG with password authentication and a PFX certificate.

.LINK
   https://github.com/jfacz/UAG-Automation
#>

# ==============================================================================
# 1. UAG APPLIANCE INVENTORY
# ==============================================================================
$UAG = @(
    @{ Name = "VDI-UAG01"; IP = "<10.0.10.11>"; User = "admin" }
)

# ==============================================================================
# 2. SSL CERTIFICATE
# ==============================================================================
$CERTS = @{
    "vdi.company.com [PFX]" = @{
        CertType     = "PFX"
        CertPfxPath  = "C:\Install\Cert\vdi_company_com.pfx"
        CertPfxAlias = ""
        CertEntity   = @("end_user")
    }
}

# ==============================================================================
# 3. UAG CONFIGURATION ("ALL" = applied to every UAG in the inventory)
# ==============================================================================
$UAG_CFG = @{}

$UAG_CFG["ALL"] = @{
    systemSettings = @{
        uagName   = "VDI-UAG01"
        dns       = "<10.0.1.10 10.0.1.11>"
        dnsSearch = "<company.com>"
    }

    edgeService = @{
        enabled             = $true
        identifier          = "VIEW"
        gatewayLocation     = "External"                       # External | Internal
        proxyDestinationUrl = "<https://vdi-cs01.company.com>" # Horizon Connection Server / load balancer
        blastEnabled        = $true
        blastExternalUrl    = "https://vdi.company.com:443"
        tunnelEnabled       = $true
        tunnelExternalUrl   = "https://vdi.company.com:443"
        trustedCertificates = @("<C:\Install\Cert\company_ca.cer>")   # CA of the Connection Server certificate
        authMethods         = "sp-auth"                        # sp-auth = password (Active Directory)
    }
}

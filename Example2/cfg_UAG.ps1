<#
.SYNOPSIS
   Configuration and inventory of Omnissa Unified Access Gateway (UAG) appliances for UAG_Config.ps1

.DESCRIPTION
   Defines UAG appliance inventory ($UAG), SSL certificates ($CERTS), global default settings ($UAG_CFG["ALL"])
   and appliance-specific overrides ($UAG_CFG["<Appliance_Name>"]).

   Values in the form <...> are placeholders - the script aborts until they are replaced with real values (or removed).

.NOTES
   Two internal UAGs (password) and two external UAGs (SAML, Let's Encrypt certificate).

.LINK
   https://github.com/jfacz/UAG-Automation
#>

# ==============================================================================
# 1. UAG APPLIANCE INVENTORY
# ==============================================================================
# Array of target UAG appliances to be configured via REST API.
$UAG = @(
    # Internal
    @{ Name = "VDI-UAGI01"; IP = "<10.0.10.11>"; User = "admin" }
    @{ Name = "VDI-UAGI02"; IP = "<10.0.10.12>"; User = "admin" }

    # External
    @{ Name = "VDI-UAGE01"; IP = "<10.0.10.21>"; User = "admin" }
    @{ Name = "VDI-UAGE02"; IP = "<10.0.10.22>"; User = "admin" }
)

# ==============================================================================
# 2. SSL CERTIFICATE DEFINITIONS
# ==============================================================================
# Hashtable of SSL certificates (PFX or PEM format) to be uploaded to UAG.
# Target Cerificate Entitiy: @("end_user"), @("admin"), or both @("end_user", "admin")
$CERTS = @{
    # PKCS#12 (PFX) Internal Certificate
    "vdi.company.com INT [PFX]" = @{
        CertType     = "PFX"
        CertPfxPath  = "<C:\Install\Cert\vdi_company_com_int.pfx>"
        CertPfxAlias = ""
        CertEntity   = @("end_user")
    }

    # PEM Public Certificate Full Chain + RSA Private Key (path of the Let's Encrypt certificate: <Posh-ACME home>\<LE_PROD|LE_STAGE>\<AccountID>\<domain>\)
    "vdi.company.com Public [PEM]" = @{
        CertType   = "PEM"
        CertPem    = "<C:\Scripts\UAG-Automation\Posh-ACME\LE_PROD\1234567890\vdi.company.com\fullchain.cer>"
        CertKeyPem = "<C:\Scripts\UAG-Automation\Posh-ACME\LE_PROD\1234567890\vdi.company.com\cert.key>"
        CertEntity = @("end_user")
    }
}

# ==============================================================================
# 3. UAG GLOBAL CONFIGURATION TEMPLATE ($UAG_CFG["ALL"])
# ==============================================================================
# "ALL" acts as the global baseline. Individual UAG instances inherit and override these values.
$UAG_CFG = @{}

$UAG_CFG["ALL"] = @{

    # --- System & General Settings ---
    systemSettings = @{
        uagName                                 = "<UagName>"
        dns                                     = "<10.0.1.10 10.0.1.11>"
        dnsSearch                               = "<company.com>"
        ntpServers                              = "<10.0.1.10 10.0.1.11>"
        #hostClockSyncEnabled                    = $true
        adminPasswordExpirationDays             = 0        # 0 = Password never expires
        monitoringUsersPasswordExpirationDays   = 0
        sessionTimeout                          = 72000000 # Idle session timeout in ms (default: 36000000 = 10h)
        unrecognizedSessionsMonitoringEnabled   = $false
        ceipEnabled                             = $false   # Customer Experience Improvement Program
        cipherSuites                            = "TLS_AES_128_GCM_SHA256,TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    }

    # --- Horizon Edge Service (View Proxy) ---
    edgeService = @{
        enabled                         = $true
        identifier                      = "VIEW"
        gatewayLocation                 = "Internal" # External | Internal
        
        # Horizon Connection Server / Load Balancer Target
        proxyDestinationUrl             = "<https://vdi-cs01.company.com>"
        proxyDestinationUrlThumbprints  = ""         # Optional SHA-256 thumbprint if trustedCertificates are omitted
        proxyDestinationIPSupport       = "IPV4"
        
        # External URLs & Gateway Services
        blastEnabled                    = $true
        blastExternalUrl                = "<https://vdi.company.com:443>"
        tunnelEnabled                   = $true
        tunnelExternalUrl               = "<https://vdi.company.com:443>"
        pcoipEnabled                    = $false

        # Trusted Root & Intermediate CA PEM files for Connection Server SSL validation
        trustedCertificates = @("<C:\Install\Cert\company_ca.cer>")

        # Primary Authentication Method
        # Options: "sp-auth" (Password) | "radius-auth" | "saml-auth" | "saml-auth,radius-auth"
        authMethods                     = "sp-auth"
    }

    # --- General UAG Settings ---
    uagSettings = @{}

    # --- User accounts (create/modify) ---
    adminUsers = @{
        "monitoring" = @{
            name                              = "monitor"
            password                          = ""
            enabled                           = $true
            roles                             = @("ROLE_MONITORING")
            userType                          = "INTERNAL"
            adminMonitoringPasswordPreExpired = $false
        }
    }
}

# ==============================================================================
# 4. APPLIANCE-SPECIFIC OVERRIDES
# ==============================================================================
# Override global defaults for specific UAG instances (e.g., custom host entries or distinct IdPs).
$idpID = "<EntraID_EntityID>"

# --- Internal UAG ---
$uagName = "VDI-UAGI01"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }

    edgeService = @{
        gatewayLocation = "Internal"
    }
}

$uagName = "VDI-UAGI02"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }

    edgeService = @{
        gatewayLocation = "Internal"
    }
}

# --- External UAG (SAML Authentication) ---
$uagName = "VDI-UAGE01"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }

    edgeService = @{
        gatewayLocation = "External"
        authMethods = "saml-auth"
        idpEntityID = $idpID
    }

    # --- SAML Identity Provider (IdP) Metadata ---
    samlSettings = @{
        idpMetadataPath = "<C:\Install\UAG\saml_metadata.xml>" # Path to Entra ID / Okta / Google XML metadata file
        entityID = $idpID
    }
}

# --- External UAG (SAML Authentication) ---
$uagName = "VDI-UAGE02"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }

    edgeService = @{
        gatewayLocation = "External"
        authMethods = "saml-auth"
        idpEntityID = $idpID
    }

    # --- SAML Identity Provider (IdP) Metadata ---
    samlSettings = @{
        idpMetadataPath = "<C:\Install\UAG\saml_metadata.xml>" # Path to Entra ID / Okta / Google XML metadata file
        entityID = $idpID
    }
}
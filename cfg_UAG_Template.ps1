<#
.SYNOPSIS
   Template configuration and inventory definition file for Omnissa Unified Access Gateway (UAG) API Management.

.DESCRIPTION
   Defines UAG appliance inventory ($UAG), SSL certificates ($CERTS), global default settings ($UAG_CFG["ALL"]), 
   and appliance-specific overrides ($UAG_CFG["<Appliance_Name>"]) used by UAG_API_Manage.ps1.

.NOTES
   Creation Date:  2026-09-12
   Last Update:    2026-09-14
#>

# ==============================================================================
# 1. UAG APPLIANCE INVENTORY
# ==============================================================================
# Array of target UAG appliances to be configured via REST API.
$UAG = @(
    # External
    @{ Name = "UAG-EXT-01"; IP = "10.0.10.11"; User = "admin" }
   ,@{ Name = "UAG-EXT-02"; IP = "10.0.10.12"; User = "admin" }
    
    # Internal
   #,@{ Name = "UAG-INT-01"; IP = "10.0.20.11"; User = "admin" }
   #,@{ Name = "UAG-INT-02"; IP = "10.0.20.12"; User = "admin" }
)

# ==============================================================================
# 2. SSL CERTIFICATE DEFINITIONS
# ==============================================================================
# Hashtable of SSL certificates (PFX or PEM format) to be uploaded to UAG.
# Target Cerificate Entitiy: @("end_user"), @("admin"), or both @("end_user", "admin")
$CERTS = @{
    # Example 1: PKCS#12 (PFX) Certificate
    "vdi.company.com (exp. 2027-01) [PFX]" = @{
        CertType     = "PFX"
        CertPfxPath  = "C:\Certs\vdi_company_com.pfx"
        CertPfxAlias = ""
        CertEntity   = @("end_user")
    }

    # Example 2: PEM Certificate Full Chain + RSA Private Key
    "vdi.company.com (exp. 2027-01) [PEM]" = @{
        CertType   = "PEM"
        CertPem    = "C:\Certs\vdi_company_com.pem"
        CertKeyPem = "C:\Certs\vdi_company_com.key"
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
        uagName                                 = "UAG-DEFAULT"
        dns                                     = "10.0.1.10 10.0.1.11"
        dnsSearch                               = "company.com"
        ntpServers                              = "10.0.1.10 10.0.1.11"
        adminPasswordExpirationDays             = 0        # 0 = Password never expires
        monitoringUsersPasswordExpirationDays   = 0
        sessionTimeout                          = 72000000 # Idle session timeout in ms (default: 36000000 = 10h)
        unrecognizedSessionsMonitoringEnabled   = $false
        hostClockSyncEnabled                    = $false
        ceipEnabled                             = $false   # Customer Experience Improvement Program
        cipherSuites                            = "TLS_AES_128_GCM_SHA256,TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    }

    # --- Horizon Edge Service (View Proxy) ---
    edgeService = @{
        enabled                         = $true
        identifier                      = "VIEW"
        gatewayLocation                 = "External" # External | Internal
        
        # Horizon Connection Server / Load Balancer Target
        proxyDestinationUrl             = "https://horizon-cs.company.com"
        proxyDestinationUrlThumbprints  = ""         # Optional SHA-256 thumbprint if trustedCertificates are omitted
        proxyDestinationIPSupport       = "IPV4"
        
        # External URLs & Gateway Services
        blastEnabled                    = $true
        blastExternalUrl                = "https://vdi.company.com:8443"
        tunnelEnabled                   = $true
        tunnelExternalUrl               = "https://vdi.company.com:443"
        pcoipEnabled                    = $false

        # Trusted Root & Intermediate CA PEM files for Connection Server SSL validation
        trustedCertificates = @(
            "C:\Certs\Company_RootCA.pem",
            "C:\Certs\Company_SubCA.pem"
        )

        # Blast / Tunnel proxy PEM certificates (optional) 
         #proxyBlastPemCert  = "C:\Certs\vdi_blast_tunnel.pem"
         #proxyTunnelPemCert = "C:\Certs\vdi_blast_tunnel.pem"

        # Primary Authentication Method
        # Options: "sp-auth" (Password) | "radius-auth" | "saml-auth" | "saml-auth,radius-auth"
        authMethods                     = "radius-auth"
         #idpEntityID                     = "Entra_ID_Company" # Links to SAML metadata entityID

        # Additional Horizon Options
        matchWindowsUserName            = $true
        windowsSSOEnabled               = $true
        radiusUsernameLabel             = "e-mail address"
        radiusPasscodeLabel             = "password"
    }

    # --- SAML Identity Provider (IdP) Metadata ---
    samlSettings = @{
        idpMetadataPath = "C:\SAML\EntraID_Metadata.xml" # Path to Entra ID / Okta / Google XML metadata file
        entityID        = "Entra_ID_Company"           # Entity ID registered in UAG
    }

    # --- RADIUS 2FA / MFA Authentication ---
    radiusSettings = @{
        name              = "radius-auth"
        enabled           = "true"
        radiusDisplayHint = "Company MFA"
        
        # Primary RADIUS Server
        hostName          = "radius1.company.com"
        authPort          = "1812"
        authType          = "MSCHAP2" # PAP | CHAP | MSCHAP2
        serverTimeout     = "8"
        numAttempts       = "3"
        sharedSecret      = "" # Handled securely via DPAPI prompt or script parameter
        
        # Secondary / Backup RADIUS Server (Optional)
        enabledAux        = "true"
        hostName_2        = "radius2.company.com"
        authPort_2        = "1812"
        authType_2        = "MSCHAP2"
        serverTimeout_2   = "8"
        numAttempts_2     = "3"
        sharedSecret_2    = "" # Handled securely via DPAPI prompt or script parameter
    }

    # --- Syslog Remote Logging ---
    syslogSettings = @{
        syslogSystemMessagesEnabled = $true
        syslogServerSettings = @(
            @{
                syslogSettingChanged          = $true
                syslogSettingName             = "SIEM_Log_Collector"
                syslogUrl                     = "siem.company.com:5140"
                syslogCategory                = "ALL"          # ALL | AUDIT_ONLY
                syslogCategoryList            = @("ALL")       # ALL, AUDIT, APPLICATION, TRACEABILITY, STATS, DEPLOYMENT
                syslogFormat                  = "TEXT"
                sysLogType                    = "UDP"          # UDP | TCP | TLS
                syslogSystemMessagesEnabledV2 = $true
            }
        )
    }

    # --- General UAG Settings ---
    uagSettings = @{}
}

# ==============================================================================
# 4. APPLIANCE-SPECIFIC OVERRIDES
# ==============================================================================
# Override global defaults for specific UAG instances (e.g., custom host entries or distinct IdPs).

# --- Override Example 1: Local Host Entries ---
$uagName = "UAG-EXT-01"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }
    edgeService = @{
        hostEntries = @("10.0.10.50 vdi.company.com")
    }
}

# --- Override Example 2: SAML Authentication ---
$uagName = "UAG-EXT-02"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }
    edgeService = @{
        authMethods = "saml-auth"
        idpEntityID = "Entra_ID_Company"
    }
}
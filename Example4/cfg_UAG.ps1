<#
.SYNOPSIS
   Configuration and inventory of Omnissa Unified Access Gateway (UAG) appliances for UAG_Config.ps1

.DESCRIPTION
   Defines UAG appliance inventory ($UAG), SSL certificates ($CERTS), global default settings ($UAG_CFG["ALL"])
   and appliance-specific overrides ($UAG_CFG["<Appliance_Name>"]).

   Values in the form <...> are placeholders - the script aborts until they are replaced with real values (or removed).

.NOTES
   Two NICs, an external and an internal UAG and an external UAG on a DR site, RADIUS MFA.

.LINK
   https://github.com/jfacz/UAG-Automation
#>

# ==============================================================================
# 1. UAG APPLIANCE INVENTORY
# ==============================================================================
# Array of target UAG appliances to be configured via REST API.
$UAG = @(
    # External
    @{ Name = "VDI-UAGE01"; IP = "<10.0.20.21>"; User = "admin" }

    # Internal
    @{ Name = "VDI-UAGI01"; IP = "<10.0.20.22>"; User = "admin" }

    # DR (External)
    @{ Name = "VDI-UAGE-DR"; IP = "<10.1.20.21>"; User = "admin" }
)

# ==============================================================================
# 2. SSL CERTIFICATE DEFINITIONS
# ==============================================================================
# Hashtable of SSL certificates (PFX or PEM format) to be uploaded to UAG.
# Target Cerificate Entitiy: @("end_user"), @("admin"), or both @("end_user", "admin")
$CERTS = @{
    # PKCS#12 (PFX) Public Certificate (Multi SAN, also used by the DR UAG)
    "vdi.company.com [PFX]" = @{
        CertType     = "PFX"
        CertPfxPath  = "C:\Install\Cert\vdi_company_com.pfx"
        CertPfxAlias = ""
        CertEntity   = @("end_user")
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
        #ntpServers                             = "<10.0.1.10 10.0.1.11>"
        hostClockSyncEnabled                    = $true
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
        blastExternalUrl                = "https://vdi.company.com:443"
        tunnelEnabled                   = $true
        tunnelExternalUrl               = "https://vdi.company.com:443"
        pcoipEnabled                    = $false

        # Trusted Root & Intermediate CA PEM files for Connection Server SSL validation
        trustedCertificates = @("<C:\Install\Cert\company_ca.cer>")

        # Primary Authentication Method
        # Options: "sp-auth" (Password) | "radius-auth" | "saml-auth" | "saml-auth,radius-auth"
        authMethods                     = "sp-auth"
    }

    # --- General UAG Settings ---
    uagSettings = @{}

    # --- Syslog Remote Logging ---
    syslogSettings = @{
        syslogSystemMessagesEnabled = $true
        syslogServerSettings = @(
            @{
                syslogSettingChanged = $true
                syslogSettingName = "Syslog"
                syslogUrl = "<10.0.1.50:514>"
                syslogCategory = "ALL" # [ALL, AUDIT_ONLY]
                syslogCategoryList = @("ALL") # [ALL, AUDIT, APPLICATION, TRACEABILITY, STATS, DEPLOYMENT]. If both syslogCategory and syslogCategoryList are configured, syslogCategory is ignored.
                syslogFormat = "TEXT"
                sysLogType = "UDP"
                syslogSystemMessagesEnabledV2 = $true
            }
        )
    }

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

# --- External UAG ---
$uagName = "VDI-UAGE01"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }

    edgeService = @{
        gatewayLocation = "External"
        authMethods = "radius-auth"
        hostEntries = @() #@("10.0.20.11 vdi-cs01.company.com vdi-cs01", "10.0.20.12 vdi-cs02.company.com vdi-cs02")

        # PCoIP
        pcoipEnabled = $true
        pcoipExternalUrl = "<203.0.113.10:4172>"
        
        # Additional Horizon Options
        disableWebClient = $true
        matchWindowsUserName = $false
        windowsSSOEnabled = $false
        radiusUsernameLabel = "e-mail address"
        radiusPasscodeLabel = "Passcode (or 'push')"
        proxyDestinationPreLoginMessageEnabled = $true
        disclaimerText = "Welcome. You are connecting to the Company environment in the primary (production) site.\n\nFor two-factor login enter the passcode from the mobile app, or type ""push"" (without quotes) to send a notification to the app."
    }
    
    # --- RADIUS 2FA / MFA Authentication ---
    radiusSettings = @{
        name              = "radius-auth"
        enabled           = "true"
        radiusDisplayHint = "Multi-Factor"

        # Primary RADIUS Server
        hostName          = "<radius1.company.com>"
        authPort          = "1812"
        authType          = "PAP" # PAP | CHAP | MSCHAP2
        serverTimeout     = "8"
        numAttempts       = "3"
        sharedSecret      = "" # Handled securely via DPAPI prompt or script parameter

        # Secondary / Backup RADIUS Server (Optional)
        enabledAux        = "true"
        hostName_2        = "<radius2.company.com>"
        authPort_2        = "1812"
        authType_2        = "PAP"
        serverTimeout_2   = "8"
        numAttempts_2     = "3"
        sharedSecret_2    = "" # Handled securely via DPAPI prompt or script parameter
    }
}


# --- Internal UAG ---
$uagName = "VDI-UAGI01"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
    }

    edgeService = @{
        gatewayLocation = "Internal"
        proxyDestinationUrl = "<https://vdi-cs02.company.com>"
        hostEntries = @() #@("10.0.20.11 vdi-cs01.company.com vdi-cs01", "10.0.20.12 vdi-cs02.company.com vdi-cs02")

        # PCoIP
        pcoipEnabled = $true
        pcoipExternalUrl = "<10.0.30.32:4172>"
    }
}


# --- VDI-UAGE-DR (External) ---
$uagName = "VDI-UAGE-DR"
$UAG_CFG[$uagName] = @{
    systemSettings = @{
        uagName = $uagName
        dns = "<10.1.1.10 10.0.1.11>"
    }

    edgeService = @{
        gatewayLocation = "External"
        proxyDestinationUrl = "<https://cs-dr.company.com>"
        blastExternalUrl = "https://vdi-dr.company.com:443"
        tunnelExternalUrl = "https://vdi-dr.company.com:443"
        authMethods = "radius-auth"
        hostEntries = @()

        # Additional Horizon Options
        disableWebClient = $true
        matchWindowsUserName = $false
        windowsSSOEnabled = $false
        radiusUsernameLabel = ""
        radiusPasscodeLabel = "Passcode (or 'push')"
        proxyDestinationPreLoginMessageEnabled = $true
        disclaimerText = "!Warning!\nYou are connecting to the backup (DR) site.\n\nThe production environment is available at: vdi.company.com"
    }
    
    # --- RADIUS 2FA / MFA Authentication ---
    radiusSettings = @{
        name              = "radius-auth"
        enabled           = "true"
        radiusDisplayHint = "Multi-Factor"

        # Primary RADIUS Server
        hostName          = "<radius1.company.com>"
        authPort          = "1812"
        authType          = "PAP" # PAP | CHAP | MSCHAP2
        serverTimeout     = "8"
        numAttempts       = "3"
        sharedSecret      = "" # Handled securely via DPAPI prompt or script parameter

        # Secondary / Backup RADIUS Server (Optional)
        enabledAux        = "true"
        hostName_2        = "<radius2.company.com>"
        authPort_2        = "1812"
        authType_2        = "PAP"
        serverTimeout_2   = "8"
        numAttempts_2     = "3"
        sharedSecret_2    = "" # Handled securely via DPAPI prompt or script parameter
    }
}

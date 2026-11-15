# Example 2 - Internal and external UAGs, SAML and Let's Encrypt

Four UAGs with one NIC (`onenic`): two **internal** ones (password authentication, internal CA certificate in PFX) and two **external** ones (SAML, e.g. Entra ID, and a Let's Encrypt certificate that `UAG_LetsEncryptCert.ps1` renews and deploys automatically).

* Only one deploy file per UAG type is included. For `VDI-UAGI02` / `VDI-UAGE02` copy it, rename it to `cfg_UAG_Deploy_<UagName>.ps1` and change `uagName` and `ip0`.
* Keep the names consistent between the files: `Name` / `IP` in `$UAG` = `uagName` / `ip0` in the deploy file, `CertName` in the deploy files = a key of `$CERTS`, `TargetUAG` in the Let's Encrypt file = names from `$UAG`.
* The Posh-ACME account ID in the certificate paths of `$CERTS` appears after the first certificate is issued.

See the [main README](../README.md) for usage.

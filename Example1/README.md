# Example 1 - Basic: one UAG, password authentication

A basic setup and a good place to start: one UAG for Horizon with one NIC, password authentication (`sp-auth`) and a PFX certificate. No SAML, RADIUS, Syslog or Let's Encrypt.

Replace the `<...>` values, keep `Name` / `IP` in `cfg_UAG.ps1` equal to `uagName` / `ip0` in the deploy file, then run `.\UAG_Deploy.ps1` (or `.\UAG_Config.ps1` for an existing UAG). See the [main README](../README.md) for usage.

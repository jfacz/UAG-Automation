# Example 3 - Internal and external UAG, RADIUS MFA and Let's Encrypt

Two UAGs with one NIC (`onenic`) sharing one Let's Encrypt certificate: `VDI-UAGI01` is **internal** (password authentication), `VDI-UAGE01` is **external** (RADIUS MFA with a backup server, Windows SSO). Both use NTP and send logs to a syslog server.

* The Posh-ACME account ID in the certificate paths of `$CERTS` appears after the first certificate is issued.

See the [main README](../README.md) for usage.

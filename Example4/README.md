# Example 4 - Two NICs, RADIUS MFA and a DR site in another vCenter

Three UAGs with two NICs (`twonic`: `eth0` = DMZ / clients, `eth1` = management) and one PFX certificate for all of them: an **external** and an **internal** UAG on the primary site, and an **external** UAG (`VDI-UAGE-DR`) on a DR site in a **different vCenter**. The external ones use RADIUS MFA.

* Both IP addresses (`ip0`, `ip1`) are set in the deploy file; the inventory in `cfg_UAG.ps1` uses the **management** address (`ip1`).
* The DR appliance file overrides `$CFG_vSphere`, so it is deployed to another vCenter while the shared defaults stay in `cfg_UAG_Deploy.ps1`.
* `cfg_UAG.ps1` shows per-UAG differences: DNS, Connection Server and external URLs, PCoIP and the login disclaimer of the DR site.

See the [main README](../README.md) for usage.

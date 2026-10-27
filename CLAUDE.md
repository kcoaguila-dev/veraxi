<!-- VERAXI_MANAGED_START (DO NOT EDIT DIRECTLY) -->
## 🧠 Veraxi Architectural Constraints (veraxi)
*Last synced: 2026-10-27 06:28:22 UTC* | Managed by `vx rules sync`

- **[auth]** Supabase RLS requires JWT tenant_id header in SSR requests
- **[auth]** New SSR auth uses Bearer session cookies
- **[security]** Never commit plain text API secrets
<!-- VERAXI_MANAGED_END -->

# Trusted Workspace Access for Microsoft Fabric — setup & validator

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A reproducible end-to-end test of **Microsoft Fabric Trusted Workspace Access (TWA)** —
allowing a Fabric Lakehouse OneLake shortcut to read from an Azure Data Lake
Storage Gen2 account whose `publicNetworkAccess` is `Disabled`.

> ⚠️ **AI-authored — review before running.** The scripts and documentation in
> this repo were authored with the assistance of an AI agent (GitHub Copilot
> CLI). They have been exercised end-to-end against a real Fabric tenant and
> the empirical findings in the failure-mode table were captured live, but you
> should still **read the scripts before running them in your own environment**
> — especially the storage account lock-down and RBAC steps. The setup script
> creates and modifies real Azure and Fabric resources and is not reversible
> by simply re-running it.
>
> If you find a bug, an inaccuracy, a missed precondition, or a better way to
> do any of this, **please open an [issue](https://github.com/dbrownems/TrustedWorkspaceAccess/issues)
> or PR** — feedback is very welcome.

This repo gives you two scripts and a reference of all the things that have to
be true for it to work:

| Script | Purpose |
|---|---|
| [`Setup-TrustedWorkspaceAccess.ps1`](Setup-TrustedWorkspaceAccess.ps1) | Idempotently provisions every Azure + Fabric resource needed for TWA. Safe to re-run. |
| [`Test-TrustedWorkspaceAccess.ps1`](Test-TrustedWorkspaceAccess.ps1) | Declarative pre-flight validator. Reads-only — never modifies anything. Reports `[OK]` / `[FAIL]` / `[INFO]` for every TWA precondition. |

Both scripts are fully parameterized — no environment-specific defaults — and
work against any Azure subscription / Fabric tenant / capacity you have access
to.

---

## Why TWA?

TWA lets a Fabric workspace read from an ADLS Gen2 account that has the
storage firewall locked down (`publicNetworkAccess = Disabled`,
`defaultAction = Deny`), without exposing the storage account on the public
internet and without a private endpoint, by adding a **resource-instance rule**
that names the workspace and a **workspace identity** that holds the storage
RBAC role. At runtime the workspace identity authenticates to ADLS Gen2
directly through the Microsoft backbone.

The single most important — and most undocumented — fact about getting TWA
working is that **at least 10 distinct preconditions** all have to be true
simultaneously, and most failure modes surface as the same generic
`[BadRequest] Unauthorized. Access to target location ... denied.` error,
making them very hard to triage. The validator script in this repo checks all
of them up-front against the control plane so you can find the missing piece
in seconds instead of hours.

---

## Quick start

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (already installed in Cloud Shell)
- PowerShell 7+ (already installed in Cloud Shell; for local runs install
  from https://aka.ms/powershell)
- Permissions in your Azure subscription: create resource groups, storage
  accounts, and storage RBAC role assignments
- Admin on a Fabric **F-SKU** (or trial) capacity — TWA is not supported on
  Power BI Premium (P/A/EM) capacities

The scripts call the Fabric public REST API via `az rest --resource
https://api.fabric.microsoft.com`, so no `fab` CLI or other modules are
required.

### Run from Azure Cloud Shell (recommended)

[Azure Cloud Shell](https://shell.azure.com) has `az` and PowerShell 7
preinstalled and is already signed in as your user — nothing to install.

1. Open <https://shell.azure.com> and pick **PowerShell** from the shell
   switcher (top-left dropdown).
2. Pick the right tenant + subscription:
   ```pwsh
   az login --tenant <yourtenant>.onmicrosoft.com   # only if not already
   az account set --subscription "<your subscription name or id>"
   ```
3. Clone this repo into your Cloud Shell home (`$HOME` is persistent across
   sessions, so this only has to be done once):
   ```pwsh
   cd ~
   git clone https://github.com/dbrownems/TrustedWorkspaceAccess.git
   cd TrustedWorkspaceAccess
   ```
4. Provision (see [Provision](#provision) below for parameter details):
   ```pwsh
   ./Setup-TrustedWorkspaceAccess.ps1 `
       -Location       centralus `
       -ResourceGroup  twa-test-rg `
       -StorageAccount mytwasa$(Get-Random -Maximum 9999) `
       -Filesystem     datalake `
       -TestFolder     testfolder `
       -Capacity       myFabricCapacity `
       -Workspace      twa-test `
       -Lakehouse      twa_test_lh `
       -Connection     twa-test-conn `
       -ShortcutName   testfolder
   ```
5. Validate:
   ```pwsh
   ./Test-TrustedWorkspaceAccess.ps1 -ResourceGroup twa-test-rg ...   # same params as Setup
   ```
6. (Optional) cleanup when done:
   ```pwsh
   az group delete -n twa-test-rg --yes --no-wait
   az rest --resource https://api.fabric.microsoft.com `
       --method delete `
       --url https://api.fabric.microsoft.com/v1/workspaces/<workspaceId>
   ```

> **Note**: the data-plane upload step (creating the test file in the
> storage account) requires network reachability to the SA. From Cloud
> Shell that works on first run because public access is briefly enabled,
> but if the SA already has `publicNetworkAccess=Disabled` the script
> reports `data plane unreachable from this host — assuming present` and
> trusts that the file exists from the previous run.

### Run locally

```powershell
git clone https://github.com/dbrownems/TrustedWorkspaceAccess.git
cd TrustedWorkspaceAccess
az login --tenant <yourtenant>.onmicrosoft.com
.\Setup-TrustedWorkspaceAccess.ps1 -Location centralus -ResourceGroup twa-test-rg ...
```

### Provision

```powershell
.\Setup-TrustedWorkspaceAccess.ps1 `
    -Location       eastus `
    -ResourceGroup  twa-test-rg `
    -StorageAccount mytwasa$(Get-Random -Maximum 9999) `
    -Filesystem     datalake `
    -TestFolder     testfolder `
    -Capacity       myFabricCapacity `
    -Workspace      twa-test `
    -Lakehouse      twa_test_lh `
    -Connection     twa-test-conn `
    -ShortcutName   testfolder
```

`SubscriptionId` and `TenantId` are optional — if omitted, the script uses
your current `az` context (and offers an interactive subscription picker if
you have more than one in the tenant).

### Verify

```powershell
.\Test-TrustedWorkspaceAccess.ps1 `
    -ResourceGroup  twa-test-rg `
    -StorageAccount mytwasaXXXX `
    -Filesystem     datalake `
    -TestFolder     testfolder `
    -Capacity       myFabricCapacity `
    -Workspace      twa-test `
    -Lakehouse      twa_test_lh `
    -Connection     twa-test-conn `
    -ShortcutName   testfolder
```

A healthy baseline reports `12 OK + 3 INFO` (the INFOs are best-effort
checks against tenant settings that usually require Fabric admin scope to
read).

---

## What the setup script does

1. Sign-in checks (`az`, `fab`) and tenant/subscription selection
2. Resource group (create if missing)
3. ADLS Gen2 storage account
   - Created with `publicNetworkAccess = Enabled` *temporarily* so the
     signed-in user can upload the test file
   - HNS enabled, `allowSharedKeyAccess = false`
4. Grant the **signed-in user** `Storage Blob Data Contributor` (data-plane
   uploads use Entra auth, not shared keys)
5. Create the filesystem and a folder containing a small test file
6. Create the Fabric workspace on the named capacity
7. **Provision the workspace identity** (poll until `applicationId` is
   populated)
8. Add the **resource-instance rule** to the storage account for
   `Microsoft.Fabric/workspaces/{workspaceId}` in the workspace's tenant
9. **Lock down** the storage account: `publicNetworkAccess = Disabled`,
   `defaultAction = Deny`
10. Grant the **workspace identity SP** `Storage Blob Data Reader` on the
    storage account
11. Create the schema-enabled lakehouse
12. Create the **Fabric connection** (ADLS Gen2 + `WorkspaceIdentity` credential)
13. Create the **OneLake shortcut** under `Files/`
14. Verify by listing through the shortcut

Each step is idempotent — re-running the script picks up where it left off.

> **Lockdown order matters.** The script unlocks the SA briefly to upload
> the test file as the signed-in user, then locks it back down once the
> resource-instance rule and RBAC for the workspace identity are in place.
> If you set `publicNetworkAccess = Disabled` *before* the resource-instance
> rule exists, you will be locked out of your own SA until you re-enable
> public access from a trusted network. (Per the
> [Microsoft docs](https://learn.microsoft.com/azure/storage/common/storage-network-security-limitations?toc=/azure/storage/blobs/toc.json&bc=/azure/storage/blobs/breadcrumb/toc.json):
> _"If you set Public network access to Disabled after previously setting it
> to Enabled from selected virtual networks and IP addresses, any resource
> instances and exceptions that you previously configured ... will remain in
> effect."_)

---

## What the validator script checks

| # | Precondition | Layer | How it's verified |
|---|---|---|---|
| 1 | Workspace exists and is on an F-SKU (or trial) capacity | Fabric | `GET /v1/workspaces/{id}` + `GET /v1/capacities` |
| 2 | Workspace identity is provisioned (`applicationId` + SP OID present) | Fabric | `GET /v1/workspaces/{id}` |
| 3 | Lakehouse exists | Fabric | `GET /v1/workspaces/{id}/lakehouses` |
| 4 | Storage account has HNS enabled | Azure | `az storage account show` |
| 5 | Storage account is **not** in an Enforced Network Security Perimeter | Azure | `az network perimeter ...` |
| 6 | Storage account has resource-instance rule for `Microsoft.Fabric/workspaces/{wsId}` in the right tenant | Azure | `az storage account show -> networkRuleSet.resourceAccessRules` |
| 7 | Workspace identity SP holds `Storage Blob Data Reader` (or higher) on the SA | Azure | `az role assignment list --assignee <spOid> --scope <saId>` |
| 8 | Connection exists, type `AzureDataLakeStorage`, `credentialDetails.type = WorkspaceIdentity`, server matches `https://<sa>.dfs.core.windows.net`, path matches the filesystem | Fabric | `GET /v1/connections/{id}` |
| 9 | Shortcut exists, target location/subpath/connectionId reference the same SA + filesystem + folder, and resolve to the configured connection | Fabric | `GET /v1/workspaces/{ws}/items/{lh}/shortcuts/Files/{name}` |
| 10 | Tenant: `ServicePrincipalAccessPermissionAPIs` enabled — only matters if a service principal (any kind, including the workspace identity used directly as a token issuer) is calling Fabric APIs; not a TWA precondition for interactive setup. Reported as `INFO` (usually requires Fabric admin to read) | Fabric tenant settings | `GET /v1/admin/tenantsettings` |

The validator never touches the data plane, so it's safe to run against
production environments and against locked-down storage accounts.

---

## Failure-mode reference

A given runtime symptom can have several distinct root causes. The entries
below map the missing precondition → the failing step → the verbatim error
returned. ✅ entries were captured live in a sandbox tenant; 📄 entries are
documented from Microsoft's reference docs.

### 1. ✅ Tenant: `ServicePrincipalAccessPermissionAPIs` enabled
*Only relevant if a service principal (any kind, including a workspace
identity SP used directly as a token issuer) is calling Fabric public APIs;
**not** a TWA precondition for interactive setup. See [scoping caveat](#tenant-sp-api-setting--important-scoping-caveat) below.*
- **Failing step:** First Fabric API call from any SP context, e.g. `GET /v1/workspaces`, `POST /v1/connections`
- **Error:** `HTTP 401 [Unauthorized] The caller is not authenticated to access this resource.`
- **Diagnostic note:** when this setting *is* enabled but the SP simply lacks workspace access, the same call returns `HTTP 401 [RequestFailed] Unable to process the request.` The errorCode delta (`Unauthorized` vs `RequestFailed`) distinguishes "tenant setting blocking" from "SP just not added to workspace yet".

### 2. 📄 Workspace assigned to F-SKU (or trial) Fabric capacity
- **Failing step:** Shortcut create / runtime read on a Power BI Premium (P/A/EM) capacity
- **Error:** `[Forbidden]` / connectivity errors on workspace-identity-backed shortcuts. TWA support is restricted to Fabric F-SKU and trial capacities.

### 3. 📄 Workspace identity provisioned
- **Failing step:** `POST /v1/connections` with `credentialDetails.type = WorkspaceIdentity`
- **Error:** Connection create blocked — there is no workspace identity SP to bind the credential to.

### 4. 📄 Storage account has hierarchical namespace (HNS, i.e. ADLS Gen2)
*HNS is set at SA-create time and is immutable.*
- **Failing step:** Shortcut runtime read of a folder subpath (the resource-instance rule itself is still accepted on a non-HNS Blob SA)
- **Error:** Files shortcut targeting a directory subpath cannot resolve over the Blob/DFS endpoints because the directory namespace doesn't exist.

### 5. ✅ SA has resource-instance rule for `Microsoft.Fabric/workspaces/{wsId}` in the right tenant
- **Failing step:** `POST /v1/workspaces/{ws}/items/{lh}/shortcuts`
- **Error:** `HTTP 400 [BadRequest] [RequestBodyValidationFailed] Unauthorized. Access to target location https://<sa>.blob.core.windows.net/<fs>/<folder> denied.`

### 6. ✅ Workspace identity SP holds `Storage Blob Data Reader` (or higher) on the SA
- **Failing step:** `POST /v1/workspaces/{ws}/items/{lh}/shortcuts`
- **Error:** `HTTP 400 [BadRequest] [RequestBodyValidationFailed] Unauthorized. Access to target location https://<sa>.blob.core.windows.net/<fs>/<folder> denied.`

### 7. 📄 SA is **not** in an Enforced Network Security Perimeter
- **Failing step:** `POST /v1/workspaces/{ws}/items/{lh}/shortcuts` once the SA is enrolled in Enforced NSP
- **Error:** Same surface error as #5/#6: `[RequestBodyValidationFailed] Unauthorized. Access to target location ... denied.`
- **Root cause:** An Enforced NSP bypasses the SA firewall entirely — `defaultAction=Deny`, IP rules, the AzureServices bypass, AND resource-instance rules are all ignored. Microsoft Fabric is not on the NSP onboarded-resources list, so an Enforced NSP silently disables TWA.

### 8. ✅ Connection `connectionDetails.parameters.server` matches the shortcut location URL (and `path` matches the filesystem)
- **Failing step:** `POST /v1/workspaces/{ws}/items/{lh}/shortcuts`
- **Error:** `HTTP 400 [BadRequest] [DMTSConnectionServerAndTargetPathMismatch] Location parameter must match URL in provided connection.`

### 9. ✅ Connection `credentialDetails.type = WorkspaceIdentity`
- **Failing step:** `POST /v1/connections`
- **Error:** `HTTP 400 [IncorrectCredentials] Failed to establish connection using the Credentials input — The credentials provided cannot be used for the AzureDataLakeStorage source.`
- **Note:** With public access disabled, any non-`WorkspaceIdentity` credential either fails the test-connection probe at create time, or — if it has its own valid auth path such as a working SAS — bypasses TWA entirely and is therefore irrelevant to TWA.

### 10. ✅ Shortcut payload `location` + `subpath` + `connectionId` are valid
- **Failing step:** `POST /v1/workspaces/{ws}/items/{lh}/shortcuts`
- **Error:** `HTTP 400 [BadRequest] [TargetNotFound] Target path doesn't exist` (when `subpath` points to a non-existent folder). Other malformed-payload variants surface as `[BadRequest]` with shape-specific `moreDetails`.

### Important: error ambiguity

The same surface error — `[RequestBodyValidationFailed] Unauthorized. Access to
target location <url> denied.` — is returned for **three different root
causes**:

1. Missing/wrong storage resource-instance rule for the workspace (#5)
2. Missing RBAC role assignment for the workspace identity SP on the SA (#6)
3. Storage account enrolled in an Enforced NSP that bypasses the SA firewall (#7)

When this error appears, you must check all three preconditions in turn.
`Test-TrustedWorkspaceAccess.ps1` checks #5 and #6 declaratively from the Azure
control plane and reports them separately. NSP enforcement (#7) is also probed
declaratively where possible.

---

## Tenant SP-API setting — important scoping caveat

The `ServicePrincipalAccessPermissionAPIs` Fabric tenant setting governs
**any** service principal (Entra app registration) calling Fabric public APIs.
Interactive users (idtyp=user) are not affected by it.

The Fabric **workspace identity** is **not** exempt — it is a normal Entra app
registration with a federated credential, so it is governed by this setting
just like any other SP. This was verified empirically end-to-end:

- Acquired a token for the workspace identity SP via the client-credentials
  flow (`POST {tenant}/oauth2/v2.0/token` with the WI app's `client_id` +
  `client_secret`, scope `https://api.fabric.microsoft.com/.default`)
- Called `GET https://api.fabric.microsoft.com/v1/workspaces`
- With the setting **disabled**: `401 Unauthorized` —
  `errorCode: Unauthorized, message: The caller is not authenticated to access this resource`
- Re-enabled the setting and waited ~15 minutes for tenant-setting propagation
- Same call: `200 OK`, body `{"value":[]}` (empty because the WI is not a
  member of any workspace as itself)

Despite this, **basic TWA setup does not require the setting to be enabled**,
because:

1. **Setup of the connection + shortcut is performed by the interactive
   user** running through the portal or `fab` CLI / `Invoke-RestMethod` with
   user creds — interactive users are not blocked by this setting.
2. **At runtime, ADLS Gen2 authenticates the workspace identity directly via
   storage-side AAD checks**; no Fabric public API call is involved on the
   hot path. So the setting does not affect runtime reads through the
   shortcut either.

This was confirmed end-to-end: with the setting **disabled** an interactive
user successfully:

1. Deleted the existing connection + shortcut
2. Re-created the ADLS Gen2 connection with `credentialDetails.type=WorkspaceIdentity`
3. Re-created the Files shortcut targeting the storage account
4. Listed through the shortcut and read the test file (workspace identity →
   ADLS Gen2 succeeded at runtime)

What this means in practice:

- **TWA does not require the setting to be enabled.** Setup performed in the
  portal or via the `fab` CLI logged in as a user works whether the setting is
  on or off. **No tenant admin involvement is required to stand up TWA**, even
  in tenants where this setting is locked to disabled by policy.
- If you set up TWA from a CI/CD pipeline running as your own SP, this setting
  being disabled blocks you at the very first Fabric API call. You'll see
  `HTTP 401 [Unauthorized] The caller is not authenticated to access this
  resource` from any endpoint, including `GET /v1/workspaces`.
- `ServicePrincipalAccessGlobalAPIs` ("Service principals can create
  workspaces, connections, and deployment pipelines") is the related sibling
  setting that gates *write* operations for SPs. The two should usually be
  flipped together for SP-based deployment scenarios.

---

## Notes on related controls (not separate preconditions)

These configurations interact with TWA but are not standalone preconditions in
the sense of "must be set or TWA fails":

- **`publicNetworkAccess`**: TWA is the *reason* you set this to `Disabled`.
  With it `Enabled` (and default `Allow`), TWA is not exercised — Fabric just
  connects via public IP. With it set to `Enabled` *with* `defaultAction=Deny`,
  both public IP allow-lists and TWA are honored. Setting it to `Disabled` is
  the strictest mode — only resource-instance rules and private endpoints
  work.
- **`bypass = AzureServices`**: This grants access to "trusted services" — but
  for the connection-via-Fabric path (which goes through Fabric's data
  movement service), the `AzureServices` bypass and the Fabric resource-
  instance rule are largely interchangeable mechanisms. If both are present,
  you cannot empirically tell which one is doing the work. To genuinely test
  the resource-instance rule, set `bypass = None`.
- **`allowSharedKeyAccess`**: Disabling this prevents Key-credential
  connections from working. With it disabled (recommended), even if you use
  the wrong credential type the connection fails fast.

---

## Troubleshooting playbook

| Symptom | First thing to check |
|---|---|
| `[RequestBodyValidationFailed] Unauthorized. Access to target location ... denied.` on shortcut create | Run the validator. The combination of resource-instance rule + workspace-identity RBAC + no Enforced NSP is the usual culprit. |
| `[DMTSConnectionServerAndTargetPathMismatch] Location parameter must match URL in provided connection` | The shortcut `location` value and the connection's `server` parameter must be exactly the same URL (`https://<sa>.dfs.core.windows.net`). The shortcut `subpath` first segment must match the connection's `path` (the filesystem name). |
| `[TargetNotFound] Target path doesn't exist` | The folder named in the shortcut `subpath` doesn't exist (yet) on the storage account, OR the workspace identity is denied at the storage layer (the API often surfaces auth failures as `TargetNotFound`). Confirm the folder exists from a permitted network. |
| `[IncorrectCredentials] The credentials provided cannot be used for the AzureDataLakeStorage source` on connection create | The `credentialDetails.type` is something other than `WorkspaceIdentity`, AND the storage account has `publicNetworkAccess = Disabled`. Use `WorkspaceIdentity`. |
| `HTTP 401 [Unauthorized] The caller is not authenticated to access this resource` from a Fabric API call | You are calling Fabric APIs from a service principal (including the workspace identity itself as a token issuer), and `ServicePrincipalAccessPermissionAPIs` is disabled in the tenant. Either flip the setting on (Fabric admin) and wait ~15 min for propagation, or do the setup as an interactive user (the recommended path — TWA itself doesn't need the setting). |
| Worked at first, started failing after a config change | Both Fabric and Azure Storage cache positive auth decisions. After breaking a precondition, an existing shortcut may continue to read for several minutes. To verify a precondition's effect, **delete and re-create** the shortcut — that forces a fresh auth round-trip. |

---

## Empirical testing methodology (how the table above was built)

The 6 "empirically tested" rows were verified by deliberately breaking the
precondition, running the dependent operation, capturing the verbatim error,
then restoring the configuration. Several techniques were necessary:

- **Use direct Fabric REST API for shortcut create** (the scripts use `az
  rest --resource https://api.fabric.microsoft.com` against the public
  `POST /v1/workspaces/{ws}/items/{lh}/shortcuts` endpoint, which preserves
  the full `moreDetails` diagnostic payload from server errors).
- **Probe at create time, not read time.** Both Fabric and Azure Storage cache
  positive access decisions. Listing through an existing shortcut may succeed
  for several minutes after a precondition is broken.
- **For the resource-instance-rule test**, also set the SA's `bypass` to
  `None`. Otherwise the `bypass = AzureServices` exception lets Fabric through
  anyway and the test reports a false negative.
- **For the SP-API tenant-setting test**, the test was done in three
  complementary parts. Part A: disable the setting → create a temporary Entra
  SP via `az ad sp create-for-rbac --skip-assignment` → acquire a Fabric-
  scope token (`https://api.fabric.microsoft.com/.default`) using
  client_credentials → call `GET /v1/workspaces` and observe `401
  [Unauthorized]`. Part B: with the setting still disabled, run the full
  WI-relevant TWA setup as an interactive user and observe that all steps
  succeed. Part C: add a client secret to the workspace identity's underlying
  app registration → acquire a Fabric token for the WI directly via
  client_credentials → call `GET /v1/workspaces`. With the setting disabled
  this returns `401 [Unauthorized]`; after re-enabling the setting and
  waiting ~15 min for tenant-setting propagation, the same call returns
  `200 OK`. This proves the WI is **not** exempt from the setting — it's a
  normal Entra app registration. TWA still works without the setting only
  because setup is performed by an interactive user and runtime ADLS auth
  doesn't traverse Fabric public APIs.

---

## References

- [Trusted workspace access](https://learn.microsoft.com/fabric/security/security-trusted-workspace-access)
- [Workspace identity in Microsoft Fabric](https://learn.microsoft.com/fabric/security/workspace-identity)
- [Configure Azure Storage firewalls and virtual networks — limitations](https://learn.microsoft.com/azure/storage/common/storage-network-security-limitations?toc=/azure/storage/blobs/toc.json&bc=/azure/storage/blobs/breadcrumb/toc.json)
- [Network Security Perimeter — concepts](https://learn.microsoft.com/azure/private-link/network-security-perimeter-concepts)
- [Fabric admin tenant settings — Developer settings](https://learn.microsoft.com/fabric/admin/service-admin-portal-developer)
- [Fabric REST API reference](https://learn.microsoft.com/rest/api/fabric/articles/)
- [`az rest` command reference](https://learn.microsoft.com/cli/azure/reference-index#az-rest)

---

## Contributing

Issues and pull requests welcome.

## License

[MIT](LICENSE) © Microsoft Corporation.

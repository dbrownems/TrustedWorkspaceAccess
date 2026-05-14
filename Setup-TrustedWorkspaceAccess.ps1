<#
.SYNOPSIS
    Idempotently provisions an Azure + Fabric Trusted Workspace Access (TWA) test scenario.

.DESCRIPTION
    Creates — or reuses, if already present — every resource required to verify
    that a Fabric Lakehouse OneLake shortcut can read an ADLS Gen2 storage
    account whose `publicNetworkAccess` is `Disabled`, via Trusted Workspace
    Access (resource-instance rule for the workspace + workspace identity
    granted RBAC on the storage account).

    Re-running the script is safe; each step probes for the resource and only
    creates it if missing. Strategy on first storage-account creation: the
    account is briefly created with public access ENABLED so the signed-in
    user can upload the test file, then locked down once the workspace
    resource-instance rule is in place.

    End state on success:
      - ADLS Gen2 SA (HNS, sharedKey disabled, public=Disabled, defaultAction=Deny)
      - Resource-instance rule for the Fabric workspace
      - Fabric workspace + workspace identity
      - Workspace identity SP granted Storage Blob Data Reader on the SA
      - Schema-enabled lakehouse
      - ADLS Gen2 connection using WorkspaceIdentity credential
      - OneLake `Files/<Shortcut>` shortcut into <Filesystem>/<TestFolder>
      - Verification listing through the shortcut

.PREREQUISITES
    - Azure CLI (`az`) installed and signed in (`az login --tenant <TenantId>`).
    - The signed-in user must be able to: create RGs and storage accounts in
      the subscription, assign RBAC on the storage account, and admin the
      target Fabric capacity.
    - All Fabric REST calls go through `az rest --resource
      https://api.fabric.microsoft.com`, so no extra CLI / module is required
      and the script runs cleanly in Azure Cloud Shell.

.PARAMETER SubscriptionId
    Azure subscription ID (GUID). Defaults to the current `az` subscription.

.PARAMETER TenantId
    Microsoft Entra tenant ID (GUID). Defaults to the current `az` tenant.

.PARAMETER Location
    Azure region for the resource group and storage account (e.g. `centralus`).

.PARAMETER ResourceGroup
    Resource group name. Created if missing.

.PARAMETER StorageAccount
    ADLS Gen2 storage account name (must be globally unique, 3-24 lowercase
    alphanumeric).

.PARAMETER Filesystem
    ADLS Gen2 filesystem (container) name to create under the storage account.

.PARAMETER TestFolder
    Folder path under the filesystem that the shortcut will point at.

.PARAMETER TestFileName
    Name of the test file uploaded into <Filesystem>/<TestFolder>/.

.PARAMETER Capacity
    Name (resource name, not display name) of the Fabric capacity that the
    workspace should be assigned to. The signed-in user must be a capacity
    admin.

.PARAMETER Workspace
    Fabric workspace name to create (or reuse).

.PARAMETER Lakehouse
    Schema-enabled lakehouse name to create (or reuse) inside the workspace.

.PARAMETER Connection
    Name of the Fabric connection (ADLS Gen2 + WorkspaceIdentity) to create
    (or reuse).

.PARAMETER ShortcutName
    Name of the OneLake shortcut to create under `Files/`. The shortcut will
    point at `https://<StorageAccount>.dfs.core.windows.net/<Filesystem>/<TestFolder>`.

.EXAMPLE
    .\Setup-TrustedWorkspaceAccess.ps1 `
        -SubscriptionId <sub-guid> `
        -TenantId       <tenant-guid> `
        -Location       centralus `
        -ResourceGroup  twa-test-rg `
        -StorageAccount twatest$(Get-Random -Maximum 9999) `
        -Capacity       myFabricCapacity

.NOTES
    Uses `az` for both Azure management/data plane and Fabric public API
    (`az rest --resource https://api.fabric.microsoft.com`). No `fab` CLI
    dependency — runs as-is in Azure Cloud Shell.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,

    [Parameter(Mandatory)] [string]$Location,
    [Parameter(Mandatory)] [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccount,

    [Parameter(Mandatory)] [string]$Filesystem,
    [Parameter(Mandatory)] [string]$TestFolder,
    [string]$TestFileName = 'test.txt',

    [Parameter(Mandatory)] [string]$Capacity,
    [Parameter(Mandatory)] [string]$Workspace,
    [Parameter(Mandatory)] [string]$Lakehouse,
    [Parameter(Mandatory)] [string]$Connection,
    [Parameter(Mandatory)] [string]$ShortcutName
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "    (exists) $msg" -ForegroundColor DarkGray }
function Write-Done($msg) { Write-Host "    [+] $msg" -ForegroundColor Green }

# ---- Fabric REST helpers -------------------------------------------------
$script:FabricResource = 'https://api.fabric.microsoft.com'
$script:FabricBase     = 'https://api.fabric.microsoft.com/v1'

function Invoke-FabricApi {
    <#
    .SYNOPSIS
        Calls the Fabric public REST API via `az rest`. Returns the parsed
        response object on success, or throws with the server error body.
        For LROs (HTTP 202), poll a state-bearing GET (e.g. `GET workspace`)
        until the desired state is observed — `az rest` doesn't expose
        response headers, so we don't try to follow Location.
    #>
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)] [string]$Path,   # e.g. "workspaces" or "workspaces/{id}"
        $Body = $null
    )
    $url = if ($Path -match '^https?://') { $Path } else { "$script:FabricBase/$($Path.TrimStart('/'))" }
    $azArgs = @('rest', '--resource', $script:FabricResource,
                '--method', $Method.ToLower(), '--url', $url,
                '--only-show-errors')
    $tmp = $null
    try {
        if ($null -ne $Body) {
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress }
            $tmp = New-TemporaryFile
            Set-Content -LiteralPath $tmp -Value $json -NoNewline -Encoding utf8
            $azArgs += @('--body', "@$tmp", '--headers', 'Content-Type=application/json')
        }
        $raw = & az @azArgs 2>&1
        $code = $LASTEXITCODE
        $text = ($raw | ForEach-Object { "$_" }) -join "`n"
        if ($code -ne 0) { throw "Fabric API $Method $Path failed:`n$text" }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json
    } finally {
        if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Find-FabricWorkspace([string]$Name) {
    $r = Invoke-FabricApi -Path 'workspaces'
    return $r.value | Where-Object { $_.displayName -ieq $Name } | Select-Object -First 1
}

function Find-FabricLakehouse([string]$WsId, [string]$Name) {
    $r = Invoke-FabricApi -Path "workspaces/$WsId/lakehouses"
    return $r.value | Where-Object { $_.displayName -ieq $Name } | Select-Object -First 1
}

function Find-FabricConnection([string]$Name) {
    $r = Invoke-FabricApi -Path 'connections'
    return $r.value | Where-Object { $_.displayName -ieq $Name } | Select-Object -First 1
}

function Find-FabricShortcut([string]$WsId, [string]$LhId, [string]$Name) {
    try {
        return Invoke-FabricApi -Path "workspaces/$WsId/items/$LhId/shortcuts/Files/$Name"
    } catch {
        return $null
    }
}

# --------------------------------------------------------------------------
# 0. Verify CLI auth
# --------------------------------------------------------------------------
Write-Step 'Verifying CLI authentication'
$azAcct = az account show --only-show-errors -o json 2>$null | ConvertFrom-Json
if (-not $azAcct) {
    if ($TenantId) { az login --tenant $TenantId --only-show-errors -o none }
    else           { az login --only-show-errors -o none }
    $azAcct = az account show --only-show-errors -o json | ConvertFrom-Json
}
if (-not $TenantId) { $TenantId = $azAcct.tenantId }

if ($azAcct.tenantId -ne $TenantId) {
    Write-Host "az is on tenant $($azAcct.tenantId) but TenantId=$TenantId — re-authenticating" -ForegroundColor Yellow
    az login --tenant $TenantId --only-show-errors -o none
    $azAcct = az account show --only-show-errors -o json | ConvertFrom-Json
}

# Interactive subscription picker if not provided
if (-not $SubscriptionId) {
    $subs = az account list --query "[?tenantId=='$TenantId']" -o json | ConvertFrom-Json |
        Sort-Object name
    if (-not $subs -or $subs.Count -eq 0) {
        throw "No Azure subscriptions visible in tenant $TenantId for the signed-in user."
    }
    if ($subs.Count -eq 1) {
        $SubscriptionId = $subs[0].id
        Write-Host "    Only one subscription available — using '$($subs[0].name)' ($SubscriptionId)" -ForegroundColor DarkGray
    } else {
        Write-Host ''
        Write-Host "Available subscriptions in tenant ${TenantId}:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $subs.Count; $i++) {
            $marker = if ($subs[$i].isDefault) { '*' } else { ' ' }
            Write-Host ("  [{0}]{1} {2}  ({3})" -f $i, $marker, $subs[$i].name, $subs[$i].id)
        }
        $defaultIdx = ($subs | ForEach-Object { $_.isDefault } | ForEach-Object { [int]$_ }).IndexOf(1)
        if ($defaultIdx -lt 0) { $defaultIdx = 0 }
        $prompt = "Select subscription [0-$($subs.Count - 1)] (default $defaultIdx)"
        $answer = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $defaultIdx }
        $idx = 0
        if (-not [int]::TryParse($answer, [ref]$idx) -or $idx -lt 0 -or $idx -ge $subs.Count) {
            throw "Invalid selection: $answer"
        }
        $SubscriptionId = $subs[$idx].id
        Write-Host "    Selected '$($subs[$idx].name)' ($SubscriptionId)" -ForegroundColor DarkGray
    }
}

az account set --subscription $SubscriptionId --only-show-errors

# Fabric API smoke-test: confirms az can mint a Fabric-aud token for this user.
try {
    $null = Invoke-FabricApi -Path 'workspaces'
} catch {
    throw "Cannot call Fabric API as the signed-in az user. Ensure 'az login --tenant $TenantId' succeeded and the user has Fabric access.`n$($_.Exception.Message)"
}
Write-Done "az authenticated to tenant $TenantId (subscription $SubscriptionId); Fabric API reachable"

# --------------------------------------------------------------------------
# 1. Resource Group
# --------------------------------------------------------------------------
Write-Step "Resource Group: $ResourceGroup"
if ((az group exists -n $ResourceGroup) -eq 'true') {
    Write-Skip $ResourceGroup
} else {
    az group create -n $ResourceGroup -l $Location --only-show-errors -o none
    Write-Done "Created RG $ResourceGroup in $Location"
}

# --------------------------------------------------------------------------
# 2. Storage Account
#    Strategy: on first creation, leave public access ENABLED briefly so the
#    signed-in user can upload the test file. Then lock down at the end.
# --------------------------------------------------------------------------
Write-Step "Storage Account: $StorageAccount"
$sa = az storage account show -n $StorageAccount -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
$saJustCreated = $false
if (-not $sa) {
    az storage account create `
        -n $StorageAccount -g $ResourceGroup -l $Location `
        --sku Standard_LRS --kind StorageV2 --hns true `
        --public-network-access Enabled `
        --default-action Allow `
        --allow-shared-key-access false `
        --only-show-errors -o none
    $sa = az storage account show -n $StorageAccount -g $ResourceGroup -o json | ConvertFrom-Json
    $saJustCreated = $true
    Write-Done "Created storage account $StorageAccount (HNS, sharedKey=disabled, public temporarily Enabled for bootstrap)"
} else { Write-Skip $StorageAccount }
$saId = $sa.id

# --------------------------------------------------------------------------
# 3. RBAC for current user (so we can do data-plane uploads)
# --------------------------------------------------------------------------
Write-Step 'Granting current user Storage Blob Data Contributor (for upload)'
$me = az ad signed-in-user show -o json | ConvertFrom-Json
$myAssignments = az role assignment list --assignee $me.id --scope $saId `
    --role 'Storage Blob Data Contributor' -o json 2>$null | ConvertFrom-Json
if (-not $myAssignments -or $myAssignments.Count -eq 0) {
    az role assignment create --assignee-object-id $me.id `
        --assignee-principal-type User `
        --role 'Storage Blob Data Contributor' --scope $saId --only-show-errors -o none | Out-Null
    Write-Done 'Role assigned'
    Write-Host '    Waiting 30s for RBAC propagation' -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
} else { Write-Skip 'role already assigned' }

# --------------------------------------------------------------------------
# 4. Filesystem + folder + test file
#    Note: When the SA is already locked down (publicNetworkAccess=Disabled)
#    and we're not on a trusted network, data-plane calls will fail. In that
#    case we assume the filesystem and test file are already present (this
#    script created them when the SA was first provisioned).
# --------------------------------------------------------------------------
function Test-StorageDataPlane {
    $null = az storage fs list --account-name $StorageAccount --auth-mode login -o json 2>&1
    return ($LASTEXITCODE -eq 0)
}

Write-Step "Filesystem: $Filesystem"
$dpReachable = Test-StorageDataPlane
if (-not $dpReachable) {
    Write-Skip "$Filesystem (data plane unreachable from this host — assuming present)"
} else {
    $existingFs = az storage fs list --account-name $StorageAccount --auth-mode login -o json | ConvertFrom-Json
    if ($existingFs -and ($existingFs.name -contains $Filesystem)) {
        Write-Skip $Filesystem
    } else {
        az storage fs create -n $Filesystem --account-name $StorageAccount --auth-mode login -o none
        Write-Done "Created filesystem $Filesystem"
    }
}

$blobPath = "$TestFolder/$TestFileName"
Write-Step "Test file: $Filesystem/$blobPath"
if (-not $dpReachable) {
    Write-Skip "$blobPath (data plane unreachable from this host — assuming present)"
} else {
    $fileMeta = az storage fs file show -p $blobPath -f $Filesystem `
        --account-name $StorageAccount --auth-mode login -o json 2>$null | ConvertFrom-Json
    if ($fileMeta -and $fileMeta.name) {
        Write-Skip $blobPath
    } else {
        $tmp = Join-Path $env:TEMP $TestFileName
        "Hello from $env:USERNAME @ $(Get-Date -Format o)" | Set-Content -LiteralPath $tmp -NoNewline
        az storage fs file upload -s $tmp -p $blobPath -f $Filesystem `
            --account-name $StorageAccount --auth-mode login --overwrite true -o none
        Remove-Item $tmp -Force
        Write-Done "Uploaded $blobPath"
    }
}

# --------------------------------------------------------------------------
# 5. Fabric Workspace
# --------------------------------------------------------------------------
Write-Step "Fabric Workspace: $Workspace (capacity $Capacity)"

# Resolve capacity name -> capacityId via Fabric API
$caps = Invoke-FabricApi -Path 'capacities'
$capObj = $caps.value | Where-Object { $_.displayName -ieq $Capacity } | Select-Object -First 1
if (-not $capObj) {
    throw "Fabric capacity '$Capacity' not found (or you are not a capacity admin). Available: $(@($caps.value.displayName) -join ', ')"
}
$capId = $capObj.id

$wsObj = Find-FabricWorkspace $Workspace
if ($wsObj) {
    Write-Skip $Workspace
} else {
    $wsObj = Invoke-FabricApi -Method POST -Path 'workspaces' -Body @{
        displayName = $Workspace
        capacityId  = $capId
    }
    Write-Done "Created workspace $Workspace"
}
$wsId = $wsObj.id
Write-Host "    workspaceId = $wsId" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 6. Workspace Identity
# --------------------------------------------------------------------------
function Get-WorkspaceIdentity([string]$WsId) {
    $w = Invoke-FabricApi -Path "workspaces/$WsId"
    return $w.workspaceIdentity
}

Write-Step 'Workspace Identity'
$idObj = Get-WorkspaceIdentity $wsId
if (-not $idObj -or -not $idObj.applicationId) {
    try {
        Invoke-FabricApi -Method POST -Path "workspaces/$wsId/provisionIdentity" | Out-Null
    } catch {
        # provisionIdentity returns 202 Accepted with no body; az rest treats
        # this as success but may surface odd behavior. Tolerate and poll.
        Write-Host "    (provisionIdentity returned: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
    Write-Host '    Waiting for identity provisioning' -NoNewline
    for ($i=0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 10
        $idObj = Get-WorkspaceIdentity $wsId
        if ($idObj -and $idObj.applicationId) { break }
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    if (-not $idObj.applicationId) { throw 'Workspace identity not provisioned in time.' }
    Write-Done "Provisioned identity AppId=$($idObj.applicationId)"
} else {
    Write-Skip "AppId=$($idObj.applicationId)"
}
$spAppId = $idObj.applicationId
$spOid   = $idObj.servicePrincipalId
if (-not $spOid) { $spOid = (az ad sp show --id $spAppId -o json | ConvertFrom-Json).id }

# --------------------------------------------------------------------------
# 7. Storage resource-instance rule
# --------------------------------------------------------------------------
Write-Step 'Storage resource-instance rule for Fabric workspace'
$wsResId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/workspaces/$wsId"
$saNet = az storage account show -n $StorageAccount -g $ResourceGroup -o json | ConvertFrom-Json
$haveRule = $saNet.networkRuleSet.resourceAccessRules |
    Where-Object { $_.resourceId -ieq $wsResId -and $_.tenantId -ieq $TenantId }
if (-not $haveRule) {
    az storage account network-rule add `
        -n $StorageAccount -g $ResourceGroup `
        --resource-id $wsResId --tenant-id $TenantId --only-show-errors -o none
    Write-Done 'Added resource-instance rule'
} else { Write-Skip 'rule already present' }

# --------------------------------------------------------------------------
# 7b. Lock down storage public access (idempotent)
# --------------------------------------------------------------------------
Write-Step 'Locking down storage account public network access'
$saCur = az storage account show -n $StorageAccount -g $ResourceGroup -o json | ConvertFrom-Json
$needsUpdate = ($saCur.publicNetworkAccess -ne 'Disabled') -or ($saCur.networkRuleSet.defaultAction -ne 'Deny')
if ($needsUpdate) {
    az storage account update -n $StorageAccount -g $ResourceGroup `
        --public-network-access Disabled `
        --default-action Deny `
        --only-show-errors -o none
    Write-Done 'publicNetworkAccess=Disabled, defaultAction=Deny'
} else { Write-Skip 'already locked down' }

# --------------------------------------------------------------------------
# 8. RBAC: workspace identity SP -> Storage Blob Data Reader
# --------------------------------------------------------------------------
Write-Step 'Granting workspace identity Storage Blob Data Reader'
$spAssignments = az role assignment list --assignee $spOid --scope $saId `
    --role 'Storage Blob Data Reader' -o json 2>$null | ConvertFrom-Json
if (-not $spAssignments -or $spAssignments.Count -eq 0) {
    az role assignment create --assignee-object-id $spOid `
        --assignee-principal-type ServicePrincipal `
        --role 'Storage Blob Data Reader' --scope $saId --only-show-errors -o none | Out-Null
    Write-Done 'Role assigned'
    Write-Host '    Waiting 30s for RBAC propagation' -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
} else { Write-Skip 'role already assigned' }

# --------------------------------------------------------------------------
# 9. Schema-enabled Lakehouse
# --------------------------------------------------------------------------
Write-Step "Lakehouse: $Lakehouse (schema-enabled)"
$lhObj = Find-FabricLakehouse $wsId $Lakehouse
if ($lhObj) {
    Write-Skip $Lakehouse
} else {
    $lhObj = Invoke-FabricApi -Method POST -Path "workspaces/$wsId/lakehouses" -Body @{
        displayName     = $Lakehouse
        creationPayload = @{ enableSchemas = $true }
    }
    Write-Done "Created lakehouse $Lakehouse"
}
$lhId = $lhObj.id
Write-Host "    lakehouseId = $lhId" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 10. Connection (ADLS Gen2 + WorkspaceIdentity)
# --------------------------------------------------------------------------
Write-Step "Fabric connection: $Connection"
$connObj = Find-FabricConnection $Connection
if ($connObj) {
    Write-Skip $Connection
} else {
    $connBody = @{
        connectivityType  = 'ShareableCloud'
        displayName       = $Connection
        connectionDetails = @{
            type           = 'AzureDataLakeStorage'
            creationMethod = 'AzureDataLakeStorage'
            parameters     = @(
                @{ name = 'server'; dataType = 'Text';
                   value = "https://$StorageAccount.dfs.core.windows.net" }
                @{ name = 'path';   dataType = 'Text'; value = $Filesystem }
            )
        }
        privacyLevel      = 'Organizational'
        credentialDetails = @{
            credentials                  = @{ credentialType = 'WorkspaceIdentity' }
            singleSignOnType             = 'None'
            connectionEncryption         = 'NotEncrypted'
            skipTestConnection           = $false
        }
    }
    $connObj = Invoke-FabricApi -Method POST -Path 'connections' -Body $connBody
    Write-Done "Created connection $Connection"
}
$connId = $connObj.id
Write-Host "    connectionId = $connId" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 11. Shortcut
# --------------------------------------------------------------------------
Write-Step "Shortcut: Files/$ShortcutName -> $StorageAccount/$Filesystem/$TestFolder"
$scExisting = Find-FabricShortcut $wsId $lhId $ShortcutName
if ($scExisting) {
    Write-Skip $ShortcutName
} else {
    $scBody = @{
        path   = 'Files'
        name   = $ShortcutName
        target = @{
            adlsGen2 = @{
                location     = "https://$StorageAccount.dfs.core.windows.net"
                subpath      = "/$Filesystem/$TestFolder"
                connectionId = $connId
            }
        }
    }
    Invoke-FabricApi -Method POST -Path "workspaces/$wsId/items/$lhId/shortcuts" -Body $scBody | Out-Null
    Write-Done "Created shortcut $ShortcutName"
}

# --------------------------------------------------------------------------
# 12. Verify by listing through the shortcut (OneLake DFS)
# --------------------------------------------------------------------------
Write-Step 'Verification: listing through shortcut'
# Fetch a storage-aud token via az, then call OneLake DFS directly with
# Invoke-RestMethod. Going through `az rest` for OneLake is fragile on
# Windows because the `&` in the query string gets mangled by az.cmd.
$names = @()
try {
    $tokRaw = az account get-access-token --resource 'https://storage.azure.com' --query accessToken -o tsv 2>$null
    if (-not $tokRaw) { throw 'Could not acquire storage-aud token via az' }
    $headers = @{
        Authorization  = "Bearer $tokRaw"
        'x-ms-version' = '2023-11-03'
    }
    # OneLake DFS uses the workspace id as the filesystem and the lakehouse
    # id (no .Lakehouse suffix) as the directory root.
    $dir = "$lhId/Files/$ShortcutName"
    $uri = "https://onelake.dfs.fabric.microsoft.com/$wsId" +
           "?resource=filesystem&recursive=false&directory=" + [uri]::EscapeDataString($dir)
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
    $names = $resp.paths | ForEach-Object { ($_.name -split '/')[-1] }
} catch {
    Write-Warning "OneLake list failed (TWA may still be configured correctly; verify manually):`n$($_.Exception.Message)"
}
if ($names -contains $TestFileName) {
    Write-Done "SUCCESS — read '$TestFileName' through shortcut. Trusted Workspace Access works."
} elseif ($names) {
    Write-Warning "Shortcut listed but '$TestFileName' not found. Files seen: $($names -join ', ')"
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
[pscustomobject]@{
    SubscriptionId = $SubscriptionId
    TenantId       = $TenantId
    ResourceGroup  = $ResourceGroup
    StorageAccount = $StorageAccount
    Filesystem     = $Filesystem
    WorkspaceId    = $wsId
    LakehouseId    = $lhId
    SpAppId        = $spAppId
    SpOid          = $spOid
    ConnectionId   = $connId
    Shortcut       = "$Workspace/$Lakehouse/Files/$ShortcutName"
} | Format-List

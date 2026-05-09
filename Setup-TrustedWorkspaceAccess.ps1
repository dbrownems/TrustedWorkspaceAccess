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
    - Fabric CLI (`fab`) installed and signed in (`fab auth login`).
    - The signed-in user must be able to: create RGs and storage accounts in
      the subscription, assign RBAC on the storage account, and admin the
      target Fabric capacity.

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
    (or reuse). Lives under `.connections/`.

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
    Uses `az` (management + data plane) and `fab` (Fabric items + connections +
    shortcuts). All Fabric REST calls go through `fab api` so no separate
    bearer-token handling is needed.
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

# ---- fab helpers --------------------------------------------------------
function Invoke-Fab {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FabArgs)
    $raw = & fab @FabArgs 2>&1
    $code = $LASTEXITCODE
    $lines = $raw | ForEach-Object { "$_" } | Where-Object {
        $_ -notmatch '^\[notice\]' -and
        $_ -notmatch 'RequestsDependencyWarning' -and
        $_ -notmatch 'changelog' -and
        $_ -notmatch '^\s*-\s' -and
        $_ -notmatch "What's new"
    }
    $text = ($lines -join "`n").Trim()
    if ($code -ne 0) { throw "fab $($FabArgs -join ' ') failed:`n$text" }
    return $text
}

function ConvertFrom-FabJson([string]$Text) {
    $start = $Text.IndexOf('{')
    if ($start -lt 0) { throw "No JSON in fab output: $Text" }
    return $Text.Substring($start) | ConvertFrom-Json
}

function Get-FabResultData {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FabArgs)
    $obj = ConvertFrom-FabJson (Invoke-Fab @FabArgs)
    , $obj.result.data
}

function Test-FabPath([string]$Path) {
    try { Invoke-Fab get $Path -q id | Out-Null; return $true }
    catch { return $false }
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

$fabStatus = Invoke-Fab auth status
if ($fabStatus -notmatch [regex]::Escape($TenantId)) {
    throw "fab CLI is not authenticated to tenant $TenantId. Run 'fab auth login'.`n$fabStatus"
}
Write-Done "az + fab authenticated to tenant $TenantId (subscription $SubscriptionId)"

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
if (Test-FabPath "$Workspace.Workspace") {
    Write-Skip $Workspace
} else {
    Invoke-Fab mkdir "$Workspace.Workspace" -P "capacityName=$Capacity" | Out-Null
    Write-Done "Created workspace $Workspace"
}
$wsId = (Get-FabResultData get "$Workspace.Workspace" -q id)[0]
Write-Host "    workspaceId = $wsId" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 6. Workspace Identity
# --------------------------------------------------------------------------
function Get-WorkspaceIdentity([string]$WsId) {
    $resp = ConvertFrom-FabJson (Invoke-Fab api "workspaces/$WsId")
    return $resp.result.data[0].text.workspaceIdentity
}

Write-Step 'Workspace Identity'
$idObj = Get-WorkspaceIdentity $wsId
if (-not $idObj -or -not $idObj.applicationId) {
    Invoke-Fab api -X post "workspaces/$wsId/provisionIdentity" | Out-Null
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
$lhPath = "$Workspace.Workspace/$Lakehouse.Lakehouse"
if (Test-FabPath $lhPath) {
    Write-Skip $Lakehouse
} else {
    Invoke-Fab mkdir $lhPath -P 'enableSchemas=true' | Out-Null
    Write-Done "Created lakehouse $Lakehouse"
}
$lhId = (Get-FabResultData get $lhPath -q id)[0]
Write-Host "    lakehouseId = $lhId" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 10. Connection (ADLS Gen2 + WorkspaceIdentity)
# --------------------------------------------------------------------------
Write-Step "Fabric connection: $Connection"
$connPath = ".connections/$Connection.Connection"
if (Test-FabPath $connPath) {
    Write-Skip $Connection
} else {
    $params = @(
        "connectionDetails.type=AzureDataLakeStorage",
        "connectionDetails.parameters.server=https://$StorageAccount.dfs.core.windows.net",
        "connectionDetails.parameters.path=$Filesystem",
        "credentialDetails.type=WorkspaceIdentity"
    ) -join ','
    Invoke-Fab mkdir $connPath -P $params | Out-Null
    Write-Done "Created connection $Connection"
}
$connId = (Get-FabResultData get $connPath -q id)[0]
Write-Host "    connectionId = $connId" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 11. Shortcut
# --------------------------------------------------------------------------
Write-Step "Shortcut: Files/$ShortcutName -> $StorageAccount/$Filesystem/$TestFolder"
$scPath = "$Workspace.Workspace/$Lakehouse.Lakehouse/Files/$ShortcutName.Shortcut"
if (Test-FabPath $scPath) {
    Write-Skip $ShortcutName
} else {
    $payload = @{
        location     = "https://$StorageAccount.dfs.core.windows.net"
        subpath      = "$Filesystem/$TestFolder"
        connectionId = $connId
    } | ConvertTo-Json -Compress
    Invoke-Fab ln $scPath --type adlsGen2 -i $payload -f | Out-Null
    Write-Done "Created shortcut $ShortcutName"
}

# --------------------------------------------------------------------------
# 12. Verify by listing through the shortcut
# --------------------------------------------------------------------------
Write-Step 'Verification: listing through shortcut'
$names = Get-FabResultData ls "$Workspace.Workspace/$Lakehouse.Lakehouse/Files/$ShortcutName" |
    ForEach-Object { $_.name }
if ($names -contains $TestFileName) {
    Write-Done "SUCCESS — read '$TestFileName' through shortcut. Trusted Workspace Access works."
} else {
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

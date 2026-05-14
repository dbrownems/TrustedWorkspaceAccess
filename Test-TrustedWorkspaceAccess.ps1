<#
.SYNOPSIS
    Declarative pre-flight validator for a Fabric Trusted Workspace Access
    (TWA) configuration. Verifies every precondition required for a
    Lakehouse OneLake shortcut to read an ADLS Gen2 storage account whose
    `publicNetworkAccess` is `Disabled`.

.DESCRIPTION
    The script DOES NOT touch the data plane. It only inspects:

      Capacity - Workspace is on an F-SKU (or trial) capacity.
      Workspace- Workspace identity is provisioned.
      Storage  - HNS enabled.
                 Not associated with an Azure Network Security Perimeter
                 in Enforced mode.
                 Resource-instance rule for Microsoft.Fabric/workspaces/<wsid>
                 with the correct tenant ID.
                 Workspace identity SP holds Storage Blob Data Reader (or
                 a higher built-in data role).
      Conn     - ADLS Gen2 connection uses WorkspaceIdentity credential.
                 Server/path point at the right SA + filesystem.
      Shortcut - Shortcut payload location/subpath/connectionId are
                 internally consistent and reference the connection.

    Exits 0 if all checks pass, 1 if any check fails. Each check prints
    [OK] / [FAIL] / [WARN] / [INFO] with a short hint for failures.

    All Fabric REST calls go through `az rest --resource
    https://api.fabric.microsoft.com`, so no `fab` CLI / extra module
    dependency. Runs as-is in Azure Cloud Shell.

.PARAMETER SubscriptionId
    Azure subscription ID (GUID). Defaults to the current `az` subscription.

.PARAMETER TenantId
    Microsoft Entra tenant ID (GUID). Defaults to the current `az` tenant.

.PARAMETER ResourceGroup
    Resource group containing the storage account.

.PARAMETER StorageAccount
    ADLS Gen2 storage account name.

.PARAMETER Filesystem
    Filesystem the shortcut should target.

.PARAMETER TestFolder
    Folder under <Filesystem> that the shortcut targets.

.PARAMETER Capacity
    Fabric capacity name the workspace is assigned to.

.PARAMETER Workspace
    Fabric workspace name.

.PARAMETER Lakehouse
    Lakehouse name.

.PARAMETER Connection
    Fabric connection name.

.PARAMETER ShortcutName
    OneLake shortcut name under Files/.

.EXAMPLE
    .\Test-TrustedWorkspaceAccess.ps1 `
        -ResourceGroup  twa-test-rg `
        -StorageAccount mytwasa `
        -Filesystem     datalake `
        -TestFolder     testfolder `
        -Capacity       myFabricCapacity `
        -Workspace      twa-test `
        -Lakehouse      twa_test_lh `
        -Connection     twa-test-conn `
        -ShortcutName   testfolder
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,

    # Accepted but ignored — present for symmetry with Setup-TrustedWorkspaceAccess.ps1
    # so the same parameter splat can be used for both.
    [string]$Location,

    [Parameter(Mandatory)] [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccount,

    [Parameter(Mandatory)] [string]$Filesystem,
    [Parameter(Mandatory)] [string]$TestFolder,

    [Parameter(Mandatory)] [string]$Capacity,
    [Parameter(Mandatory)] [string]$Workspace,
    [Parameter(Mandatory)] [string]$Lakehouse,
    [Parameter(Mandatory)] [string]$Connection,
    [Parameter(Mandatory)] [string]$ShortcutName
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---- Result tracking ----------------------------------------------------
$script:results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param(
        [ValidateSet('OK','FAIL','WARN','INFO','SKIP')] [string]$Status,
        [string]$Id,
        [string]$Message,
        [string]$Hint = ''
    )
    $script:results.Add([pscustomobject]@{
        Id      = $Id
        Status  = $Status
        Message = $Message
        Hint    = $Hint
    })
    $color = switch ($Status) {
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        'INFO' { 'Cyan' }
        'SKIP' { 'DarkGray' }
    }
    Write-Host ("[{0,-4}] {1,-22} {2}" -f $Status, $Id, $Message) -ForegroundColor $color
    if ($Hint) { Write-Host "         hint: $Hint" -ForegroundColor DarkGray }
}

# ---- Fabric REST helpers -------------------------------------------------
$script:FabricResource = 'https://api.fabric.microsoft.com'
$script:FabricBase     = 'https://api.fabric.microsoft.com/v1'

function Invoke-FabricApi {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)] [string]$Path,
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

function Try-FabricApi {
    param([string]$Method = 'GET', [Parameter(Mandatory)] [string]$Path, $Body = $null)
    try { return Invoke-FabricApi -Method $Method -Path $Path -Body $Body }
    catch { return $null }
}

# --------------------------------------------------------------------------
# 0. Auth + subscription
# --------------------------------------------------------------------------
Write-Host '== TWA Pre-flight Validator ==' -ForegroundColor Cyan
Write-Host ''

$azAcct = az account show --only-show-errors -o json 2>$null | ConvertFrom-Json
if (-not $azAcct) {
    Write-Host 'az is not signed in. Run `az login`.' -ForegroundColor Red
    exit 2
}
if (-not $TenantId)       { $TenantId       = $azAcct.tenantId }
if (-not $SubscriptionId) { $SubscriptionId = $azAcct.id }

if ($azAcct.id -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors
}

# Smoke-test Fabric API access
$smoke = Try-FabricApi -Path 'workspaces'
if (-not $smoke) {
    Write-Host 'Cannot call Fabric API. Verify `az login` and that you have Fabric access.' -ForegroundColor Red
    exit 2
}

Write-Host ("Tenant:        {0}" -f $TenantId)
Write-Host ("Subscription:  {0}" -f $SubscriptionId)
Write-Host ("Signed in as:  {0}" -f $azAcct.user.name)
Write-Host ''

# --------------------------------------------------------------------------
# 1. Workspace + capacity
# --------------------------------------------------------------------------
$wsList = Try-FabricApi -Path 'workspaces'
$wsObj  = if ($wsList) { $wsList.value | Where-Object { $_.displayName -ieq $Workspace } | Select-Object -First 1 } else { $null }
$wsId   = if ($wsObj) { $wsObj.id } else { $null }
if (-not $wsId) {
    Add-Result FAIL 'workspace' "Workspace '$Workspace' not found" `
        -Hint 'Run Setup-TrustedWorkspaceAccess.ps1 to provision it.'
} else {
    Add-Result OK 'workspace' "Workspace '$Workspace' = $wsId"

    # Capacity SKU
    $wsDetail = Try-FabricApi -Path "workspaces/$wsId"
    $capId = if ($wsDetail) { $wsDetail.capacityId } else { $null }
    if (-not $capId) {
        Add-Result FAIL 'capacity-fsku' 'Workspace has no capacity assigned' `
            -Hint "Assign workspace to capacity '$Capacity'."
    } else {
        $caps = Try-FabricApi -Path 'capacities'
        $capObj = if ($caps) { $caps.value | Where-Object { $_.id -ieq $capId } | Select-Object -First 1 } else { $null }
        $sku = if ($capObj) { $capObj.sku } else { $null }
        if ($sku -match '^F\d') {
            Add-Result OK 'capacity-fsku' "Workspace on $sku capacity ($capId)"
        } elseif ($sku -match '^FT|Trial') {
            Add-Result WARN 'capacity-fsku' "Workspace on $sku capacity ($capId)" `
                -Hint 'Trial capacity may not support workspace identity in all regions; F SKU recommended.'
        } elseif ($sku) {
            Add-Result FAIL 'capacity-fsku' "Capacity SKU '$sku' may not support workspace identity" `
                -Hint 'TWA requires an F SKU (or trial in supported regions).'
        } else {
            Add-Result WARN 'capacity-fsku' "Could not read capacity SKU for capacityId=$capId" `
                -Hint 'Verify the Capacity name parameter is correct.'
        }
    }

    # Workspace identity
    $idObj = if ($wsDetail) { $wsDetail.workspaceIdentity } else { $null }
    if ($idObj -and $idObj.applicationId) {
        Add-Result OK 'ws-identity' "Workspace identity AppId=$($idObj.applicationId)"
        $script:spAppId = $idObj.applicationId
        $script:spOid   = $idObj.servicePrincipalId
        if (-not $script:spOid) {
            $sp = az ad sp show --id $script:spAppId -o json 2>$null | ConvertFrom-Json
            if ($sp) { $script:spOid = $sp.id }
        }
    } else {
        Add-Result FAIL 'ws-identity' 'Workspace identity not provisioned' `
            -Hint "POST workspaces/$wsId/provisionIdentity (or run Setup-TrustedWorkspaceAccess.ps1)."
    }
}

# --------------------------------------------------------------------------
# 2. Storage account: existence, HNS, NSP, network rules
# --------------------------------------------------------------------------
$saJson = az storage account show -n $StorageAccount -g $ResourceGroup -o json 2>$null
$sa = if ($saJson) { $saJson | ConvertFrom-Json } else { $null }
if (-not $sa) {
    Add-Result FAIL 'sa-exists' "Storage account '$StorageAccount' not found in RG '$ResourceGroup'"
    Add-Result SKIP 'sa-hns' 'Skipped (SA missing)'
    Add-Result SKIP 'sa-not-in-nsp-enforced' 'Skipped (SA missing)'
    Add-Result SKIP 'sa-resource-rule' 'Skipped (SA missing)'
    Add-Result SKIP 'sa-rbac-reader' 'Skipped (SA missing)'
} else {
    Add-Result OK 'sa-exists' "Storage account exists ($($sa.location), $($sa.kind))"

    if ($sa.isHnsEnabled) {
        Add-Result OK 'sa-hns' 'HNS enabled (ADLS Gen2)'
    } else {
        Add-Result FAIL 'sa-hns' 'HNS NOT enabled' `
            -Hint 'TWA shortcuts target ADLS Gen2; HNS is set at SA creation and cannot be enabled later. Recreate the SA.'
    }

    # NSP association probe (best-effort)
    $nspAssocs = $null
    try {
        $assocOut = az rest --method get `
            --url "https://management.azure.com$($sa.id)/providers/Microsoft.Network/networkSecurityPerimeterAssociations?api-version=2024-06-01-preview" `
            --only-show-errors -o json 2>$null
        if ($assocOut) { $nspAssocs = ($assocOut | ConvertFrom-Json).value }
    } catch { $nspAssocs = $null }

    if ($null -eq $nspAssocs) {
        Add-Result INFO 'sa-not-in-nsp-enforced' 'Could not enumerate NSP associations (RP may be unregistered or no permission)' `
            -Hint 'Manually verify the SA is not associated with an NSP in Enforced mode (Fabric is not on the NSP onboarded-resources list).'
    } elseif ($nspAssocs.Count -eq 0) {
        Add-Result OK 'sa-not-in-nsp-enforced' 'SA has no NSP associations'
    } else {
        $enforced = $nspAssocs | Where-Object { $_.properties.accessMode -ieq 'Enforced' }
        if ($enforced) {
            Add-Result FAIL 'sa-not-in-nsp-enforced' "SA is in NSP(s) in Enforced mode: $(($enforced.name) -join ', ')" `
                -Hint 'Enforced NSP bypasses the SA firewall (incl. trusted-services + resource-instance rules). Fabric is NOT onboarded to NSP. Switch the perimeter to Transition mode or remove the association.'
        } else {
            Add-Result OK 'sa-not-in-nsp-enforced' "SA in $($nspAssocs.Count) NSP(s), all in Transition/Learning (firewall still enforced)"
        }
    }

    # Resource-instance rule
    if ($wsId) {
        $wsResId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/workspaces/$wsId"
        $rule = $sa.networkRuleSet.resourceAccessRules | Where-Object {
            $_.resourceId -ieq $wsResId -and $_.tenantId -ieq $TenantId
        }
        if ($rule) {
            Add-Result OK 'sa-resource-rule' "Resource-instance rule present for workspace $wsId"
        } else {
            Add-Result FAIL 'sa-resource-rule' 'No resource-instance rule for this workspace' `
                -Hint "Run: az storage account network-rule add -n $StorageAccount -g $ResourceGroup --resource-id $wsResId --tenant-id $TenantId"
        }
    } else {
        Add-Result SKIP 'sa-resource-rule' 'Skipped (workspace missing)'
    }

    Add-Result INFO 'sa-public-access' "publicNetworkAccess=$($sa.publicNetworkAccess), defaultAction=$($sa.networkRuleSet.defaultAction)"

    # RBAC for workspace identity SP
    if ($script:spOid) {
        $allowedRoles = @(
            'Storage Blob Data Reader',
            'Storage Blob Data Contributor',
            'Storage Blob Data Owner'
        )
        $assignments = az role assignment list --assignee $script:spOid --scope $sa.id -o json 2>$null | ConvertFrom-Json
        $matchRole = $assignments | Where-Object { $allowedRoles -contains $_.roleDefinitionName }
        if ($matchRole) {
            Add-Result OK 'sa-rbac-reader' "SP has '$(($matchRole.roleDefinitionName | Select-Object -Unique) -join ', ')' on SA"
        } else {
            Add-Result FAIL 'sa-rbac-reader' "Workspace identity SP ($script:spOid) lacks Storage Blob Data Reader on SA" `
                -Hint "Run: az role assignment create --assignee-object-id $script:spOid --assignee-principal-type ServicePrincipal --role 'Storage Blob Data Reader' --scope $($sa.id)"
        }
    } else {
        Add-Result SKIP 'sa-rbac-reader' 'Skipped (workspace identity SP unknown)'
    }
}

# --------------------------------------------------------------------------
# 3. Connection
# --------------------------------------------------------------------------
$connList = Try-FabricApi -Path 'connections'
$connObj  = if ($connList) { $connList.value | Where-Object { $_.displayName -ieq $Connection } | Select-Object -First 1 } else { $null }
$connId   = if ($connObj) { $connObj.id } else { $null }
if (-not $connId) {
    Add-Result FAIL 'connection-exists' "Connection '$Connection' not found"
    Add-Result SKIP 'conn-cred-type' 'Skipped (connection missing)'
    Add-Result SKIP 'conn-server-path' 'Skipped (connection missing)'
} else {
    Add-Result OK 'connection-exists' "Connection '$Connection' = $connId"

    $connDetail = Try-FabricApi -Path "connections/$connId"

    $credType = $connDetail.credentialDetails.credentialType
    if ($credType -ieq 'WorkspaceIdentity') {
        Add-Result OK 'conn-cred-type' "credentialType=$credType"
    } else {
        Add-Result FAIL 'conn-cred-type' "credentialType=$credType (expected WorkspaceIdentity)" `
            -Hint 'TWA requires the connection to use the WorkspaceIdentity credential.'
    }

    # The Fabric Connections API exposes connectionDetails as
    # { type, path } where path is the fully qualified URL the connection
    # targets, e.g. https://<sa>.dfs.core.windows.net/<filesystem>.
    $connType = $connDetail.connectionDetails.type
    $connPath = $connDetail.connectionDetails.path
    $expectedPath  = "https://$StorageAccount.dfs.core.windows.net/$Filesystem"
    $expectedPath2 = "$expectedPath/"
    $typeOk = ($connType -ieq 'AzureDataLakeStorage')
    $pathOk = ($connPath -ieq $expectedPath) -or ($connPath -ieq $expectedPath2)
    if ($typeOk -and $pathOk) {
        Add-Result OK 'conn-server-path' "type=$connType, path=$connPath"
    } else {
        $bits = @()
        if (-not $typeOk) { $bits += "type='$connType' (expected AzureDataLakeStorage)" }
        if (-not $pathOk) { $bits += "path='$connPath' (expected '$expectedPath')" }
        Add-Result FAIL 'conn-server-path' ($bits -join '; ') `
            -Hint 'Recreate the connection with the correct type/path; an existing wrong connection cannot be edited safely.'
    }
}

# --------------------------------------------------------------------------
# 4. Shortcut payload
# --------------------------------------------------------------------------
if ($wsId -and $connId) {
    # Resolve lakehouse id
    $lhList = Try-FabricApi -Path "workspaces/$wsId/lakehouses"
    $lhObj  = if ($lhList) { $lhList.value | Where-Object { $_.displayName -ieq $Lakehouse } | Select-Object -First 1 } else { $null }
    $lhId   = if ($lhObj) { $lhObj.id } else { $null }

    if (-not $lhId) {
        Add-Result FAIL 'shortcut-exists' "Lakehouse '$Lakehouse' not found in workspace"
        Add-Result SKIP 'shortcut-payload' 'Skipped (lakehouse missing)'
    } else {
        $sc = Try-FabricApi -Path "workspaces/$wsId/items/$lhId/shortcuts/Files/$ShortcutName"
        if (-not $sc) {
            Add-Result FAIL 'shortcut-exists' "Shortcut Files/$ShortcutName not found"
            Add-Result SKIP 'shortcut-payload' 'Skipped (shortcut missing)'
        } else {
            Add-Result OK 'shortcut-exists' "Shortcut Files/$ShortcutName present"

            $expectedLoc     = "https://$StorageAccount.dfs.core.windows.net"
            $expectedSubpath = "$Filesystem/$TestFolder"
            $tgt = $sc.target.adlsGen2
            if ($tgt) {
                $locOk     = ($tgt.location -ieq $expectedLoc)
                $subpathOk = (($tgt.subpath.TrimStart('/')) -ieq $expectedSubpath)
                $connOk    = ($tgt.connectionId -ieq $connId)
                if ($locOk -and $subpathOk -and $connOk) {
                    Add-Result OK 'shortcut-payload' "location/subpath/connectionId all match"
                } else {
                    $bits = @()
                    if (-not $locOk)     { $bits += "location='$($tgt.location)' (want '$expectedLoc')" }
                    if (-not $subpathOk) { $bits += "subpath='$($tgt.subpath)' (want '$expectedSubpath')" }
                    if (-not $connOk)    { $bits += "connectionId='$($tgt.connectionId)' (want '$connId')" }
                    Add-Result FAIL 'shortcut-payload' ($bits -join '; ') `
                        -Hint 'Delete and recreate the shortcut with the correct payload.'
                }
            } else {
                Add-Result FAIL 'shortcut-payload' 'Shortcut target.adlsGen2 missing' `
                    -Hint 'Shortcut may be the wrong type (not adlsGen2). Recreate.'
            }
        }
    }
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '== Summary ==' -ForegroundColor Cyan
$grouped = $script:results | Group-Object Status | Sort-Object Name
foreach ($g in $grouped) {
    $color = switch ($g.Name) { 'OK'{'Green'} 'FAIL'{'Red'} 'WARN'{'Yellow'} 'INFO'{'Cyan'} default{'DarkGray'} }
    Write-Host ("  {0,-5} {1}" -f $g.Name, $g.Count) -ForegroundColor $color
}
$failed = $script:results | Where-Object Status -in @('FAIL')
if ($failed) {
    Write-Host ''
    Write-Host 'Failed checks:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $($_.Id): $($_.Message)" -ForegroundColor Red }
    exit 1
}
Write-Host ''
Write-Host 'All declarative TWA preconditions satisfied.' -ForegroundColor Green
exit 0

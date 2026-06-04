# =============================================================================
# Fabric.ps1 - Helper functions for the Microsoft Fabric REST API
# =============================================================================
# Dot-source this from deploy.ps1:   . "$PSScriptRoot\scripts\Fabric.ps1"
#
# All functions assume the caller has run `az login` and has Fabric admin
# rights in the tenant (capacity admin is set via Bicep to the SQL admin UPN).
#
# Reference: https://learn.microsoft.com/rest/api/fabric/
# =============================================================================

$script:FabricApiBase = 'https://api.fabric.microsoft.com/v1'

function Get-FabricToken {
    <#
    .SYNOPSIS
        Returns a bearer token for the Fabric REST API.
    #>
    $json = az account get-access-token --resource 'https://api.fabric.microsoft.com' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Failed to obtain Fabric API access token. Are you logged in (az login)?"
    }
    return ($json | ConvertFrom-Json).accessToken
}

function Invoke-FabricRest {
    <#
    .SYNOPSIS
        Wraps Invoke-RestMethod with auth + JSON content + LRO handling.
    .DESCRIPTION
        Returns a hashtable:
          @{ Status = '<HTTP code>'; Body = <parsed body>; OperationLocation = '<header>' }
        Long-running operations (HTTP 202) include the Location/Operation-Location
        header so the caller can poll Wait-FabricOperation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PATCH','PUT','DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,   # e.g. /workspaces  (leading slash optional)
        [object]$Body
    )

    $uri = if ($Path.StartsWith('http')) { $Path } else { "$($script:FabricApiBase)/$($Path.TrimStart('/'))" }
    $headers = @{
        Authorization = "Bearer $Token"
        'Content-Type' = 'application/json'
    }

    $params = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        ErrorAction = 'Stop'
        # Capture response headers + status for LRO handling
        ResponseHeadersVariable = 'respHeaders'
        StatusCodeVariable      = 'respStatus'
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 50 -Compress)
    }

    # Retry transient transport-level / 5xx / 429 errors. Fabric occasionally
    # returns 'unexpected EOF', SSL handshake failures, or 502/503/504 when the
    # front door is under load -- these are safe to retry. 4xx (other than 429)
    # is not retried. 429s honor Retry-After or the "blocked by upstream service
    # until: <UTC timestamp>" message, which can be many minutes out.
    $maxAttempts = 8
    $resp = $null
    $errMsg = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $resp = Invoke-RestMethod @params
            $errMsg = $null
            break
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errMsg += "`nResponse: $($_.ErrorDetails.Message)"
            }
            $isTransient = $false
            if ($respStatus -in 429, 500, 502, 503, 504) { $isTransient = $true }
            if ($errMsg -match 'unexpected EOF|SSL connection could not be established|actively refused|operation has timed out|underlying connection was closed|0 bytes from the transport stream') {
                $isTransient = $true
            }
            if (-not $isTransient -or $attempt -eq $maxAttempts) {
                throw "Fabric API $Method $Path failed: $errMsg"
            }
            $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt))
            if ($respStatus -eq 429) {
                # Prefer server-supplied Retry-After (seconds)
                $retryAfter = $null
                try { $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch {}
                if ($retryAfter) { $delay = [int]$retryAfter }
                # Fall back to parsing the "blocked by upstream service until: <UTC>" hint
                elseif ($errMsg -match 'blocked by the upstream service until:\s*([^"]+?)\s*\(UTC\)') {
                    try {
                        $until = [datetime]::Parse($matches[1], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                        $secs = [int]([Math]::Ceiling(($until - [datetime]::UtcNow).TotalSeconds))
                        if ($secs -gt 0) { $delay = [Math]::Min(600, $secs + 2) }
                    } catch {}
                }
                else { $delay = [int][Math]::Min(120, 15 * $attempt) }
            }
            Write-Host "  Fabric API $Method $Path transient error (attempt $attempt/$maxAttempts); retrying in ${delay}s: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
        }
    }

    $opLoc = $null
    foreach ($key in @('Location','Operation-Location','x-ms-operation-id')) {
        if ($respHeaders -and $respHeaders.ContainsKey($key)) {
            $opLoc = ($respHeaders[$key] | Select-Object -First 1)
            if ($opLoc) { break }
        }
    }

    return @{
        Status            = $respStatus
        Body              = $resp
        OperationLocation = $opLoc
    }
}

function Wait-FabricOperation {
    <#
    .SYNOPSIS
        Polls a long-running operation URL until terminal state.
    .DESCRIPTION
        Fabric LROs return 202 + a Location header pointing at /v1/operations/{id}.
        We poll until status is Succeeded / Failed / Undefined.
        Throws on Failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$OperationLocation,
        [int]$TimeoutSeconds = 1800,
        [int]$PollSeconds   = 5,
        [string]$Label      = 'operation'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ((Get-Date) -gt $deadline) {
            throw "Timed out after $TimeoutSeconds s waiting for $Label ($OperationLocation)"
        }
        $r = Invoke-FabricRest -Token $Token -Method GET -Path $OperationLocation
        $status = $r.Body.status
        if ($status -in @('Succeeded')) {
            return $r.Body
        }
        if ($status -in @('Failed','Undefined')) {
            $detail = $r.Body | ConvertTo-Json -Depth 10
            throw "$Label failed: $detail"
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# -----------------------------------------------------------------------------
# Workspaces
# -----------------------------------------------------------------------------

function Get-FabricWorkspaceByName {
    <#
    .SYNOPSIS
        Returns the workspace object (or $null) for the given displayName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Name
    )
    $r = Invoke-FabricRest -Token $Token -Method GET -Path '/workspaces'
    return $r.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
}

function New-FabricWorkspace {
    <#
    .SYNOPSIS
        Creates a workspace (or returns the existing one if name already taken).
    .PARAMETER CapacityId
        The Fabric capacity GUID (NOT the ARM resource ID). Derive with:
            ($outputs.fabricCapacityId.value -split '/')[-1]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$CapacityId,
        [string]$Description = ''
    )
    $existing = Get-FabricWorkspaceByName -Token $Token -Name $Name
    if ($existing) {
        Write-Verbose "Workspace '$Name' already exists (id=$($existing.id)); reusing."
        # Make sure it's bound to our capacity
        if ($existing.capacityId -ne $CapacityId) {
            Set-FabricWorkspaceCapacity -Token $Token -WorkspaceId $existing.id -CapacityId $CapacityId
        }
        return $existing
    }
    $body = @{
        displayName = $Name
        description = $Description
        capacityId  = $CapacityId
    }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path '/workspaces' -Body $body
    return $r.Body
}

function Set-FabricWorkspaceCapacity {
    <#
    .SYNOPSIS
        Assigns a workspace to a capacity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$CapacityId
    )
    $body = @{ capacityId = $CapacityId }
    Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/assignToCapacity" -Body $body | Out-Null
}

# -----------------------------------------------------------------------------
# Lakehouses
# -----------------------------------------------------------------------------

function New-FabricWarehouse {
    <#
    .SYNOPSIS
        Creates a Fabric Warehouse in the given workspace. If one with the same
        name exists, returns it. Warehouse creation is async via LRO.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Description = ''
    )

    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/warehouses"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    if ($existing) {
        Write-Verbose "Warehouse '$Name' already exists (id=$($existing.id)); reusing."
        return $existing
    }

    $body = @{ displayName = $Name }
    if ($Description) { $body.description = $Description }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/warehouses" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create warehouse $Name" | Out-Null
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/warehouses"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

function New-FabricLakehouse {
    <#
    .SYNOPSIS
        Creates a lakehouse (with schemas enabled) in the given workspace.
        If one with the same name exists, returns it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name
    )

    # Check for existing
    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/lakehouses"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    if ($existing) {
        Write-Verbose "Lakehouse '$Name' already exists (id=$($existing.id)); reusing."
        return $existing
    }

    $body = @{
        displayName       = $Name
        creationPayload   = @{ enableSchemas = $true }
    }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/lakehouses" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create lakehouse $Name" | Out-Null
        # Re-list to get the created object
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/lakehouses"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Get-FabricCapacityGuidFromArmId {
    <#
    .SYNOPSIS
        Bicep returns the ARM resource id (.../Microsoft.Fabric/capacities/<name>).
        The Fabric REST API needs the capacity *GUID*, which we look up by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$CapacityName
    )
    $r = Invoke-FabricRest -Token $Token -Method GET -Path '/capacities'
    $cap = $r.Body.value | Where-Object { $_.displayName -eq $CapacityName } | Select-Object -First 1
    if (-not $cap) {
        throw "Fabric capacity '$CapacityName' not found in the tenant. It may still be provisioning - wait 30s and retry, or check the Azure portal."
    }
    return $cap.id
}

# -----------------------------------------------------------------------------
# Notebooks
# -----------------------------------------------------------------------------

function New-FabricNotebookFromFile {
    <#
    .SYNOPSIS
        Uploads a .ipynb (or .py with %% magic) into a workspace.
        Returns the notebook item. If a notebook with the same name exists,
        UPDATES its definition in place.
    .PARAMETER NotebookPath
        Local path to the source notebook. Must be .ipynb JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$NotebookPath,
        [string]$FolderId
    )
    if (-not (Test-Path $NotebookPath)) {
        throw "Notebook file not found: $NotebookPath"
    }
    $bytes  = [System.IO.File]::ReadAllBytes($NotebookPath)
    $base64 = [Convert]::ToBase64String($bytes)

    $definition = @{
        format = 'ipynb'
        parts  = @(
            @{
                path        = 'notebook-content.ipynb'
                payload     = $base64
                payloadType = 'InlineBase64'
            }
        )
    }

    # Check for existing
    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/notebooks"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1

    if ($existing) {
        Write-Verbose "Notebook '$Name' exists (id=$($existing.id)); updating definition."
        $body = @{ definition = $definition }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/notebooks/$($existing.id)/updateDefinition" -Body $body
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "update notebook $Name" | Out-Null
        }
        return $existing
    }

    $body = @{
        displayName = $Name
        definition  = $definition
    }
    if ($FolderId) { $body.folderId = $FolderId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/notebooks" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create notebook $Name" | Out-Null
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/notebooks"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

function Invoke-FabricNotebook {
    <#
    .SYNOPSIS
        Triggers an on-demand notebook run and polls until it finishes.
    .PARAMETER Parameters
        Hashtable of name -> @{ value=...; type='string'|'int'|...} entries
        passed to the notebook as injected parameters.
    .PARAMETER TimeoutSeconds
        Max wait. Seeding 50k orders typically runs in 5-15 minutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$NotebookId,
        [hashtable]$Parameters,
        [int]$TimeoutSeconds = 3600,
        [int]$PollSeconds   = 15,
        # Auto-retry transient Fabric Spark cluster allocation failures
        # (CLUSTER_CREATION_TIMED_OUT, cluster Cancelled before Ready, etc.).
        # These happen capacity-side and unblock on a fresh submit.
        [int]$ClusterRetries = 2
    )

    $body = $null
    if ($Parameters -and $Parameters.Count -gt 0) {
        $body = @{
            executionData = @{
                parameters = $Parameters
            }
        }
    }

    $attempt = 0
    $tok = $Token
    while ($true) {
        $attempt++
        $r = Invoke-FabricRest -Token $tok -Method POST `
            -Path "/workspaces/$WorkspaceId/items/$NotebookId/jobs/instances?jobType=RunNotebook" `
            -Body $body

        if (-not $r.OperationLocation) {
            throw "Notebook run did not return an operation location (status=$($r.Status))"
        }

        Write-Verbose "Polling notebook job at $($r.OperationLocation) (attempt $attempt)"
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $terminal = $null
        while ($true) {
            if ((Get-Date) -gt $deadline) {
                throw "Notebook run timed out after $TimeoutSeconds s"
            }
            try {
                $status = Invoke-FabricRest -Token $tok -Method GET -Path $r.OperationLocation
            } catch {
                # Fabric tokens are ~1h. Long Spark waits (cluster-starved
                # capacity, big notebooks) blow past that. Refresh on
                # TokenExpired / 401 and keep polling -- the job itself is
                # still running server-side.
                if ($_.Exception.Message -match 'TokenExpired|401 \(Unauthorized\)') {
                    Write-Warning "Fabric token expired during notebook poll; refreshing and retrying"
                    $tok = Get-FabricToken
                    Start-Sleep -Seconds 2
                    continue
                }
                throw
            }
            $s = $status.Body.status
            if ($s -in @('Completed','Succeeded')) {
                return $status.Body
            }
            if ($s -in @('Failed','Cancelled','Deduped')) {
                $terminal = $status.Body
                break
            }
            Start-Sleep -Seconds $PollSeconds
        }

        $errCode = $terminal.failureReason.errorCode
        $errMsg  = [string]$terminal.failureReason.message
        $transient = ($errCode -eq 'CLUSTER_CREATION_TIMED_OUT') -or `
                     ($errMsg -match 'Cluster was in terminal state=\[Cancelled\] before it reached ''Ready''')
        if ($transient -and $attempt -le $ClusterRetries) {
            Write-Warning "Notebook run hit transient Spark cluster allocation failure ($errCode); retrying ($attempt/$ClusterRetries)"
            Start-Sleep -Seconds 30
            continue
        }
        $detail = $terminal | ConvertTo-Json -Depth 10
        throw "Notebook run finished with status '$($terminal.status)': $detail"
    }
}

function New-FabricDataPipelineFromFile {
    <#
    .SYNOPSIS
        Creates (or updates) a Fabric Data Pipeline from a local
        pipeline-content.json file. Supports token-replacement so callers
        can bake notebook/workspace/lakehouse IDs into a template at
        deploy time.
    .PARAMETER Replacements
        Hashtable of literal token -> value pairs applied to the JSON
        text before upload. Use with placeholder tokens like
        __WEATHER_NOTEBOOK_ID__ in the source file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DefinitionPath,
        [hashtable]$Replacements,
        [string]$FolderId
    )
    if (-not (Test-Path $DefinitionPath)) {
        throw "Pipeline definition file not found: $DefinitionPath"
    }
    $json = Get-Content -Raw -Path $DefinitionPath
    if ($Replacements) {
        foreach ($k in $Replacements.Keys) {
            $json = $json.Replace($k, [string]$Replacements[$k])
        }
    }
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($json)
    $base64 = [Convert]::ToBase64String($bytes)

    $definition = @{
        parts = @(
            @{
                path        = 'pipeline-content.json'
                payload     = $base64
                payloadType = 'InlineBase64'
            }
        )
    }

    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/dataPipelines"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1

    if ($existing) {
        Write-Verbose "Pipeline '$Name' exists (id=$($existing.id)); updating definition."
        $body = @{ definition = $definition }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/dataPipelines/$($existing.id)/updateDefinition" -Body $body
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "update pipeline $Name" | Out-Null
        }
        return $existing
    }

    $body = @{
        displayName = $Name
        definition  = $definition
    }
    if ($FolderId) { $body.folderId = $FolderId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/dataPipelines" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create pipeline $Name" | Out-Null
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/dataPipelines"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

function Invoke-FabricDataPipeline {
    <#
    .SYNOPSIS
        Triggers an on-demand pipeline run and polls until it finishes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$PipelineId,
        [hashtable]$Parameters,
        [int]$TimeoutSeconds = 1800,
        [int]$PollSeconds   = 15
    )
    $body = $null
    if ($Parameters -and $Parameters.Count -gt 0) {
        $body = @{ executionData = @{ parameters = $Parameters } }
    }
    $start = Invoke-FabricRest -Token $Token -Method POST `
        -Path "/workspaces/$WorkspaceId/items/$PipelineId/jobs/instances?jobType=Pipeline" `
        -Body $body
    $statusUri = $start.Location
    if (-not $statusUri) { $statusUri = $start.OperationLocation }
    if ($start.Status -ne 202 -or -not $statusUri) {
        throw "Pipeline run did not start as expected (status=$($start.Status))"
    }
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = Invoke-FabricRest -Token $Token -Method GET -Path $statusUri
        $s = $status.Body.status
        if ($s -in @('Completed','Succeeded')) { return $status.Body }
        if ($s -in @('Failed','Cancelled','Deduped')) {
            $detail = $status.Body | ConvertTo-Json -Depth 10
            throw "Pipeline run finished with status '$s': $detail"
        }
        Start-Sleep -Seconds $PollSeconds
    }
    throw "Pipeline run did not complete within $TimeoutSeconds seconds"
}

# -----------------------------------------------------------------------------
# Mirrored Database (Azure SQL -> bronze lakehouse via change feed)
# -----------------------------------------------------------------------------

function New-FabricFolder {
    <#
    .SYNOPSIS
        Creates a workspace folder (or returns existing) by displayName.
        Idempotent: a second call with the same name returns the existing id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$DisplayName,
        [string]$ParentFolderId
    )
    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/folders"
    $existing = $list.Body.value | Where-Object {
        $_.displayName -eq $DisplayName -and
        (($ParentFolderId -and $_.parentFolderId -eq $ParentFolderId) -or (-not $ParentFolderId -and -not $_.parentFolderId))
    } | Select-Object -First 1
    if ($existing) { return $existing }
    $body = @{ displayName = $DisplayName }
    if ($ParentFolderId) { $body.parentFolderId = $ParentFolderId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/folders" -Body $body
    return $r.Body
}

function Move-FabricItemToFolder {
    <#
    .SYNOPSIS
        Moves an item into a workspace folder (or to workspace root if FolderId
        is empty). Idempotent: re-moving to current location is a no-op server-
        side. Swallows ItemNotFound for items that were already deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$ItemId,
        [string]$FolderId
    )
    $body = @{}
    if ($FolderId) { $body.targetFolderId = $FolderId }
    try {
        Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/items/$ItemId/move" -Body $body | Out-Null
    } catch {
        $msg = "$_"
        if ($msg -match 'ItemNotFound') { Write-Verbose "Move skipped: item $ItemId not found." ; return }
        throw
    }
}

function Add-FabricWorkspaceRoleAssignment {
    <#
    .SYNOPSIS
        Adds a principal to a workspace with a given role. Used to grant the
        Azure SQL logical server's system-assigned managed identity (SAMI)
        Contributor on the workspace -- mirrored databases require the SQL
        server SAMI to have read+write on the mirror item, which the Fabric
        portal grants automatically on UI-driven creation but the REST create
        flow does NOT. Without this, mirror tables stay "Initialized" forever
        with no rows replicated and no error surfaced.
    .NOTES
        Idempotent: re-adding the same principal returns an error containing
        PrincipalAlreadyHasWorkspaceAccess (or similar), which we swallow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$PrincipalId,
        [Parameter(Mandatory)] [ValidateSet('User','Group','ServicePrincipal','ServicePrincipalProfile')] [string]$PrincipalType,
        [Parameter(Mandatory)] [ValidateSet('Admin','Member','Contributor','Viewer')] [string]$Role
    )
    $body = @{
        principal = @{ id = $PrincipalId; type = $PrincipalType }
        role      = $Role
    }
    try {
        Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/roleAssignments" -Body $body | Out-Null
    } catch {
        $msg = "$_"
        if ($msg -match 'PrincipalAlreadyHasWorkspaceAccess|AlreadyExists|already') {
            # benign on re-run
        } else {
            throw
        }
    }
}

function Enable-FabricWorkspaceIdentity {
    <#
    .SYNOPSIS
        Provisions a system-assigned managed identity for the workspace. The
        identity is created as a service principal in Entra with displayName
        equal to the workspace name. Idempotent: returns existing identity
        details if already provisioned.
    .OUTPUTS
        Hashtable with applicationId, servicePrincipalId, and displayName
        (the workspace name, which is what you use in T-SQL CREATE USER FROM
        EXTERNAL PROVIDER).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId
    )

    $ws = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId").Body
    if (-not $ws.workspaceIdentity) {
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/provisionIdentity"
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "provision workspace identity" | Out-Null
        }
        $ws = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId").Body
    }
    if (-not $ws.workspaceIdentity) {
        throw "Workspace identity provisioning returned but identity is still missing on the workspace."
    }
    return @{
        applicationId        = $ws.workspaceIdentity.applicationId
        servicePrincipalId   = $ws.workspaceIdentity.servicePrincipalId
        displayName          = $ws.displayName  # what T-SQL CREATE USER FROM EXTERNAL PROVIDER sees
    }
}

function New-FabricSqlConnection {
    <#
    .SYNOPSIS
        Creates a Fabric cloud connection of type SQL (Azure SQL DB) that
        authenticates via a workspace identity. The returned connection ID is
        used as source.typeProperties.connection on a Mirrored Database.
    .DESCRIPTION
        Idempotent on $DisplayName: if a connection with that name already
        exists, returns its id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$SqlServerFqdn,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$WorkspaceId   # identity owner
    )

    # Check for an existing connection by display name
    $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/connections").Body
    $existing = $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    if ($existing) { return $existing }

    $body = @{
        connectivityType  = 'ShareableCloud'
        displayName       = $DisplayName
        connectionDetails = @{
            type           = 'SQL'
            creationMethod = 'SQL'
            parameters     = @(
                @{ dataType = 'Text'; name = 'server';   value = $SqlServerFqdn }
                @{ dataType = 'Text'; name = 'database'; value = $DatabaseName }
            )
        }
        privacyLevel      = 'Organizational'
        credentialDetails = @{
            singleSignOnType     = 'None'
            connectionEncryption = 'Encrypted'
            skipTestConnection   = $false
            credentials          = @{
                credentialType = 'WorkspaceIdentity'
                workspaceId    = $WorkspaceId
            }
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/connections" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create connection $DisplayName" | Out-Null
        $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/connections").Body
        return $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    }
    return $r.Body
}

function New-FabricMirroredAzureSqlDatabase {
    <#
    .SYNOPSIS
        Creates a Mirrored Database item that replicates the given Azure SQL DB
        into the workspace, authenticated via a pre-created Fabric connection
        (typically WorkspaceIdentity-backed). Mirroring takes a one-time
        snapshot, then streams changes via Change Tracking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ConnectionId
    )

    # Mirror definition references a Fabric connection by id (the connection
    # owns the SQL endpoint + auth). We mirror ALL tables; refine later via
    # the Fabric portal if needed.
    # NOTE: source.typeProperties.landingZone is REQUIRED. Without it the mirror
    # is created and reports status "Running" but the snapshot engine never
    # kicks off -- tables sit at "Initialized" with rows=0 forever and no
    # error is surfaced via REST. The Fabric UI sets this when you create a
    # mirror via the portal; the REST docs omit it.
    $mirroringJson = @{
        properties = @{
            source = @{
                type           = 'AzureSqlDatabase'
                typeProperties = @{
                    connection  = $ConnectionId
                    landingZone = @{
                        type           = 'MountedRelationalDatabase'
                        typeProperties = @{}
                    }
                }
            }
            target = @{
                type           = 'MountedRelationalDatabase'
                typeProperties = @{
                    defaultSchema             = 'dbo'
                    format                    = 'Delta'
                    retentionInDays           = 1
                    enableDeltaChangeDataFeed = $false
                }
            }
        }
    } | ConvertTo-Json -Depth 20 -Compress
    $mirroringB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($mirroringJson))

    $body = @{
        displayName = $Name
        definition = @{
            parts = @(
                @{
                    path        = 'mirroring.json'
                    payload     = $mirroringB64
                    payloadType = 'InlineBase64'
                }
            )
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/mirroredDatabases" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create mirrored db $Name" | Out-Null
    }

    # Look up the created item id
    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/mirroredDatabases"
    $created = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1

    # Start mirroring (retry while item is still Initializing -- can take
    # 30-90s after creation before Fabric accepts startMirroring)
    if ($created) {
        $deadline = (Get-Date).AddSeconds(300)
        while ($true) {
            try {
                Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/mirroredDatabases/$($created.id)/startMirroring" | Out-Null
                break
            } catch {
                if ($_.Exception.Message -match 'Initializing' -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 10
                    continue
                }
                throw
            }
        }
    }
    return $created
}

# -----------------------------------------------------------------------------
# VNet Data Gateway + gateway-bound SQL connection + Workspace MPE
# -----------------------------------------------------------------------------
# These three together let the mirror + notebook JDBC writes work while the
# Azure SQL server has publicNetworkAccess=Disabled:
#   - New-FabricVNetGateway: provisions a VNet Data Gateway in the customer's
#     delegated subnet. Carries Mirroring + connection-test traffic.
#   - New-FabricSqlGatewayConnection: ServicePrincipal-auth SQL connection
#     bound to the gateway. Mirror references this. WorkspaceIdentity is NOT
#     accepted for VirtualNetworkGateway connections (DMTS_InvalidCredentialTypeError).
#   - New-FabricWorkspaceManagedPrivateEndpoint: workspace-scoped MPE used by
#     Spark notebooks for JDBC writes. Independent of the gateway.

function New-FabricVNetGateway {
    <#
    .SYNOPSIS
        Creates a Fabric VNet Data Gateway in the given delegated subnet.
        Idempotent on $DisplayName.
    .NOTES
        POST /v1/gateways occasionally hangs the HTTP client even though the
        server-side create completes. We POST, then GET-loop on /v1/gateways
        until the named gateway appears or we time out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$CapacityId,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VirtualNetworkName,
        [Parameter(Mandatory)] [string]$SubnetName,
        [int]$InactivityMinutesBeforeSleep = 30,
        [int]$NumberOfMemberGateways = 1
    )

    $existing = (Invoke-FabricRest -Token $Token -Method GET -Path '/gateways').Body.value |
        Where-Object { $_.type -eq 'VirtualNetwork' -and $_.displayName -eq $DisplayName } |
        Select-Object -First 1
    if ($existing) { return $existing }

    $body = @{
        type                         = 'VirtualNetwork'
        displayName                  = $DisplayName
        capacityId                   = $CapacityId
        inactivityMinutesBeforeSleep = $InactivityMinutesBeforeSleep
        numberOfMemberGateways       = $NumberOfMemberGateways
        virtualNetworkAzureResource  = @{
            subscriptionId    = $SubscriptionId
            resourceGroupName = $ResourceGroupName
            virtualNetworkName = $VirtualNetworkName
            subnetName        = $SubnetName
        }
    }
    # Fire the POST but don't trust the response -- Invoke-RestMethod can hang
    # even when the server-side create succeeds. POST in a try, then GET-loop
    # to confirm.
    try {
        Invoke-FabricRest -Token $Token -Method POST -Path '/gateways' -Body $body | Out-Null
    } catch {
        $errMsg = "$_"
        if ($errMsg -notmatch '409|Conflict|already') { Write-Verbose "Gateway POST returned: $errMsg" }
    }
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $list = (Invoke-FabricRest -Token $Token -Method GET -Path '/gateways').Body.value
        $found = $list | Where-Object { $_.type -eq 'VirtualNetwork' -and $_.displayName -eq $DisplayName } | Select-Object -First 1
        if ($found) { return $found }
        Start-Sleep -Seconds 10
    }
    throw "VNet gateway '$DisplayName' did not appear within 5 minutes after POST."
}

function New-FabricSqlGatewayConnection {
    <#
    .SYNOPSIS
        Creates a Fabric SQL connection bound to a VNet Data Gateway,
        authenticating as a Service Principal. The returned connection id is
        used as source.typeProperties.connection on a Mirrored Database that
        targets a SQL server with publicNetworkAccess=Disabled.
    .NOTES
        VirtualNetworkGateway connections REJECT credentialType=WorkspaceIdentity
        (DMTS_InvalidCredentialTypeError). Service Principal is required; the
        SP must already exist as a SQL user with appropriate rights on the
        target database.
        skipTestConnection=false: Fabric attempts a live SQL login through the
        gateway during create. If the SP grant or PE+DNS isn't in place, this
        call fails with a descriptive error rather than the connection
        appearing healthy and then failing at mirror create time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$GatewayId,
        [Parameter(Mandatory)] [string]$SqlServerFqdn,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$ServicePrincipalAppId,
        [Parameter(Mandatory)] [string]$ServicePrincipalSecret
    )

    $list = (Invoke-FabricRest -Token $Token -Method GET -Path '/connections').Body
    $existing = $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    if ($existing) { return $existing }

    $body = @{
        connectivityType  = 'VirtualNetworkGateway'
        gatewayId         = $GatewayId
        displayName       = $DisplayName
        connectionDetails = @{
            type           = 'SQL'
            creationMethod = 'SQL'
            parameters     = @(
                @{ dataType = 'Text'; name = 'server';   value = $SqlServerFqdn }
                @{ dataType = 'Text'; name = 'database'; value = $DatabaseName }
            )
        }
        privacyLevel      = 'Organizational'
        credentialDetails = @{
            singleSignOnType     = 'None'
            connectionEncryption = 'Encrypted'
            skipTestConnection   = $false
            credentials          = @{
                credentialType            = 'ServicePrincipal'
                tenantId                  = $TenantId
                servicePrincipalClientId  = $ServicePrincipalAppId
                servicePrincipalSecret    = $ServicePrincipalSecret
            }
        }
    }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path '/connections' -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create gateway connection $DisplayName" | Out-Null
        $list = (Invoke-FabricRest -Token $Token -Method GET -Path '/connections').Body
        return $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    }
    return $r.Body
}

function New-FabricWorkspaceManagedPrivateEndpoint {
    <#
    .SYNOPSIS
        Creates a workspace-scoped Managed Private Endpoint to an Azure
        resource, approves the resulting Pending PE on the target resource,
        and waits for the MPE to reach provisioningState=Succeeded.
    .DESCRIPTION
        Used so Spark notebooks running in the workspace can reach a target
        resource (e.g. Azure SQL) over a private network path while the
        target's publicNetworkAccess is Disabled. The MPE is a separate
        transport from the VNet Data Gateway -- gateway carries Mirroring +
        connection-test traffic, MPE carries Spark notebook traffic.
        Idempotent on $Name.
    .PARAMETER TargetResourceId
        Full ARM resource id of the target (e.g. SQL server, storage account).
    .PARAMETER TargetSubresourceType
        Sub-resource type per private link (e.g. 'sqlServer', 'dfs', 'blob').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$TargetResourceId,
        [Parameter(Mandatory)] [string]$TargetSubresourceType,
        [string]$RequestMessage = 'Approved automatically by deploy.ps1'
    )

    $existing = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/managedPrivateEndpoints").Body.value |
        Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $existing) {
        $body = @{
            name                        = $Name
            targetPrivateLinkResourceId = $TargetResourceId
            targetSubresourceType       = $TargetSubresourceType
            requestMessage              = $RequestMessage
        }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/managedPrivateEndpoints" -Body $body
        $existing = $r.Body
        if (-not $existing -or -not $existing.id) {
            # POST returned without an id (e.g. 202); list to find it
            Start-Sleep -Seconds 5
            $existing = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/managedPrivateEndpoints").Body.value |
                Where-Object { $_.name -eq $Name } | Select-Object -First 1
        }
    }
    if (-not $existing) { throw "Failed to create or find MPE '$Name' in workspace $WorkspaceId" }

    # Approve the Pending PE that landed on the target resource. The MPE name
    # on the target is "{workspaceId}.{mpeName}-{guid}". We approve any
    # Pending PE matching the workspaceId+mpeName prefix.
    $approveDeadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $approveDeadline) {
        $peListJson = az network private-endpoint-connection list --id $TargetResourceId -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $peListJson) {
            $peList = $peListJson | ConvertFrom-Json
            $pending = $peList | Where-Object {
                $_.properties.privateLinkServiceConnectionState.status -eq 'Pending' -and
                $_.name -like "$WorkspaceId.$Name-*"
            } | Select-Object -First 1
            if ($pending) {
                az network private-endpoint-connection approve --id $pending.id --description $RequestMessage --output none 2>$null
                break
            }
        }
        Start-Sleep -Seconds 10
    }

    # Wait for MPE provisioningState=Succeeded (usually 2-4 minutes total).
    $readyDeadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $readyDeadline) {
        $m = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/managedPrivateEndpoints/$($existing.id)").Body
        if ($m.provisioningState -eq 'Succeeded' -and $m.connectionState.status -eq 'Approved') {
            return $m
        }
        if ($m.provisioningState -eq 'Failed') {
            throw "MPE '$Name' provisioning failed: $($m | ConvertTo-Json -Depth 6)"
        }
        Start-Sleep -Seconds 15
    }
    throw "MPE '$Name' did not reach Succeeded/Approved within 10 minutes."
}

# -----------------------------------------------------------------------------
# OneLake Shortcut (ADLS Gen2 -> bronze lakehouse Files area)
# -----------------------------------------------------------------------------

function New-FabricAdlsGen2Connection {
    <#
    .SYNOPSIS
        Creates a Fabric cloud connection of type AzureDataLakeStorage Gen2
        that authenticates via a workspace identity. The returned connection
        ID is used as target.adlsGen2.connectionId on a shortcut.
    .DESCRIPTION
        Idempotent on $DisplayName: returns existing connection id if present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [string]$WorkspaceId
    )

    $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/connections").Body
    $existing = $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    if ($existing) { return $existing }

    $server = "https://$StorageAccountName.dfs.core.windows.net"
    $body = @{
        connectivityType  = 'ShareableCloud'
        displayName       = $DisplayName
        connectionDetails = @{
            type           = 'AzureDataLakeStorage'
            creationMethod = 'AzureDataLakeStorage'
            parameters     = @(
                @{ dataType = 'Text'; name = 'server'; value = $server }
                @{ dataType = 'Text'; name = 'path';   value = '/' }
            )
        }
        privacyLevel      = 'Organizational'
        credentialDetails = @{
            singleSignOnType     = 'None'
            connectionEncryption = 'Encrypted'
            skipTestConnection   = $false
            credentials          = @{
                credentialType = 'WorkspaceIdentity'
                workspaceId    = $WorkspaceId
            }
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/connections" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create connection $DisplayName" | Out-Null
        $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/connections").Body
        return $list.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    }
    return $r.Body
}

function New-FabricAdlsShortcut {
    <#
    .SYNOPSIS
        Creates an ADLS Gen2 shortcut under the lakehouse Files/ area so the
        notebook-written CSV/Parquet files appear inline in the lakehouse.
    .PARAMETER ShortcutName
        Folder name that will appear under Files/ in the lakehouse.
    .PARAMETER StorageAccountName
        Just the account name (no .dfs.core.windows.net).
    .PARAMETER Container
        The ADLS container name (e.g. 'raw').
    .PARAMETER SubPath
        Optional sub-path inside the container (empty = container root).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$LakehouseId,
        [Parameter(Mandatory)] [string]$ShortcutName,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [string]$Container,
        [Parameter(Mandatory)] [string]$ConnectionId,
        [string]$SubPath = ''
    )

    $location = "https://$StorageAccountName.dfs.core.windows.net"
    $subPath  = if ($SubPath) { "/$Container/$($SubPath.TrimStart('/'))" } else { "/$Container" }

    $body = @{
        path   = 'Files'
        name   = $ShortcutName
        target = @{
            adlsGen2 = @{
                location     = $location
                subpath      = $subPath
                connectionId = $ConnectionId
            }
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts" -Body $body
    return $r.Body
}

function New-FabricOneLakeShortcut {
    <#
    .SYNOPSIS
        Creates a OneLake shortcut from one Fabric item (target) into another
        item (host), typically used to project a bronze Delta table into the
        silver_raw lakehouse without copying data.
    .PARAMETER HostWorkspaceId
        Workspace that owns the lakehouse where the shortcut LIVES.
    .PARAMETER HostItemId
        Lakehouse id where the shortcut appears.
    .PARAMETER ShortcutPath
        Parent path under the host lakehouse, e.g. 'Tables' or 'Tables/dbo'.
    .PARAMETER ShortcutName
        Folder/table name as it should appear under ShortcutPath.
    .PARAMETER TargetWorkspaceId
        Workspace that owns the source Delta data.
    .PARAMETER TargetItemId
        Source item id (lakehouse, mirrored database, KQL database, etc).
    .PARAMETER TargetPath
        Full path inside the target item, e.g. 'Tables/weather' or
        'Tables/dbo/customers'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$HostWorkspaceId,
        [Parameter(Mandatory)] [string]$HostItemId,
        [Parameter(Mandatory)] [string]$ShortcutPath,
        [Parameter(Mandatory)] [string]$ShortcutName,
        [Parameter(Mandatory)] [string]$TargetWorkspaceId,
        [Parameter(Mandatory)] [string]$TargetItemId,
        [Parameter(Mandatory)] [string]$TargetPath
    )

    $body = @{
        path   = $ShortcutPath
        name   = $ShortcutName
        target = @{
            oneLake = @{
                workspaceId = $TargetWorkspaceId
                itemId      = $TargetItemId
                path        = $TargetPath
            }
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$HostWorkspaceId/items/$HostItemId/shortcuts" -Body $body
    return $r.Body
}

function Enable-FabricKqlTableOneLakeMirroring {
    <#
    .SYNOPSIS
        Turns on per-table OneLake mirroring (one-logical-copy) on a KQL
        table so it becomes shortcuttable as Delta. Replication lag is ~1hr.
    .NOTES
        Idempotent: .alter-merge produces no-op when policy already matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$QueryServiceUri,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$TableName
    )
    $csl = ".alter-merge table ['$TableName'] policy mirroring dataformat=parquet with (IsEnabled=true)"
    Invoke-KustoMgmt -QueryServiceUri $QueryServiceUri -DatabaseName $DatabaseName -Csl $csl | Out-Null
}



function New-FabricEventhouse {
    <#
    .SYNOPSIS
        Creates an Eventhouse in the workspace. Idempotent on displayName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Description = ''
    )
    $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/eventhouses").Body
    $existing = $list.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    if ($existing) {
        Write-Verbose "Eventhouse '$Name' exists (id=$($existing.id))"
        return $existing
    }
    $body = @{ displayName = $Name }
    if ($Description) { $body.description = $Description }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/eventhouses" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create eventhouse $Name" | Out-Null
        $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/eventhouses").Body
        return $list.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

function New-FabricKqlDatabaseWithSchema {
    <#
    .SYNOPSIS
        Creates a KQL database under an Eventhouse with table + ingestion
        mapping baked into the definition. This is REQUIRED for Eventstream
        Eventhouse DirectIngestion destinations -- creating table/mapping
        via Kusto mgmt API after the fact leaves the table un-registered in
        the Fabric catalog, so Fabric never provisions the Kusto pull
        data connection and the eventstream destination stays in "Warning".
        See: https://learn.microsoft.com/fabric/real-time-intelligence/event-streams/api-kusto-pull-destination
    .PARAMETER SchemaKql
        Multi-line KQL script. Must include .create-merge table ...
        and .create-or-alter table ... ingestion json mapping '<name>' "...".
    .OUTPUTS
        KQL database object (with id and properties.queryServiceUri).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$EventhouseItemId,
        [Parameter(Mandatory)] [string]$SchemaKql,
        [string]$Description = ''
    )
    $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/kqlDatabases").Body
    $existing = $list.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    if ($existing) {
        Write-Verbose "KQL DB '$Name' exists (id=$($existing.id))"
        return $existing
    }

    $dbProps = @{
        databaseType                = 'ReadWrite'
        parentEventhouseItemId      = $EventhouseItemId
        oneLakeCachingPeriod        = 'P36500D'
        oneLakeStandardStoragePeriod = 'P36500D'
    } | ConvertTo-Json -Depth 5 -Compress

    $body = @{
        displayName = $Name
        description = $Description
        definition  = @{
            parts = @(
                @{ path = 'DatabaseProperties.json'
                   payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dbProps))
                   payloadType = 'InlineBase64' }
                @{ path = 'DatabaseSchema.kql'
                   payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SchemaKql))
                   payloadType = 'InlineBase64' }
            )
        }
    }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/kqlDatabases" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create kqldb $Name" | Out-Null
    }
    $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/kqlDatabases").Body
    return $list.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
}

function Invoke-KustoMgmt {
    <#
    .SYNOPSIS
        Runs a Kusto .control command against a Fabric KQL database.
    .PARAMETER QueryServiceUri
        From kqlDatabase.properties.queryServiceUri.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$QueryServiceUri,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$Csl
    )
    $json = az account get-access-token --resource $QueryServiceUri --output json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to get Kusto token for $QueryServiceUri" }
    $tok = ($json | ConvertFrom-Json).accessToken
    $body = @{ db = $DatabaseName; csl = $Csl } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method POST -Uri "$QueryServiceUri/v1/rest/mgmt" `
        -Headers @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' } `
        -Body $body -ErrorAction Stop
    return $r
}

function Grant-FabricKqlDatabaseWorkspaceIdentityAccess {
    <#
    .SYNOPSIS
        Grants the workspace managed identity Ingestor + Viewer access to a
        KQL database. Required so the Eventstream-provisioned Kusto pull
        data connection can write to the table.
    .PARAMETER WorkspaceIdentityAppId
        From (Enable-FabricWorkspaceIdentity).applicationId.
    .PARAMETER TenantId
        AAD tenant GUID. Defaults to current az login tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$QueryServiceUri,
        [Parameter(Mandatory)] [string]$DatabaseName,
        [Parameter(Mandatory)] [string]$WorkspaceIdentityAppId,
        [string]$TenantId
    )
    if (-not $TenantId) {
        $TenantId = (az account show --query tenantId -o tsv 2>$null)
    }
    $principal = "aadapp=$WorkspaceIdentityAppId;$TenantId"
    foreach ($role in @('ingestors','viewers')) {
        $csl = ".add database ['$DatabaseName'] $role ('$principal') 'Fabric workspace identity for eventstream'"
        try {
            Invoke-KustoMgmt -QueryServiceUri $QueryServiceUri -DatabaseName $DatabaseName -Csl $csl | Out-Null
        } catch {
            # Idempotent: ignore already-exists
            if ("$_" -notmatch 'already|Exists') { throw }
        }
    }
}

# -----------------------------------------------------------------------------
# Eventstream (CustomEndpoint -> Eventhouse DirectIngestion)
# -----------------------------------------------------------------------------

function New-FabricEventstreamWithEventhouseDest {
    <#
    .SYNOPSIS
        Creates an Eventstream with a CustomEndpoint source (Fabric-managed
        SAS endpoint -- exempt from Azure EH tenant SAS policies) and an
        Eventhouse DirectIngestion destination, then resumes the stream so
        it starts pulling.
    .DESCRIPTION
        The destination's Kusto data connection is auto-provisioned by Fabric
        ONLY IF the target table + ingestion mapping were declared in the KQL
        database definition (DatabaseSchema.kql). Use
        New-FabricKqlDatabaseWithSchema to set that up.

        IMPORTANT: KqlDatabaseItemId must be the id of the KQL Database item
        (the child item under the Eventhouse), NOT the Eventhouse item id.
        An Eventhouse can host multiple KQL DBs, so the parent eventhouse id
        cannot be used to disambiguate the destination -- using it leaves the
        destination stuck in 'Warning' status with no ingestion failures and
        no auto-provisioned Kusto data connection.
    .OUTPUTS
        Hashtable with eventstreamId, sourceId, sourceName, destinationId,
        and connectionName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$KqlDatabaseItemId,
        [Parameter(Mandatory)] [string]$TableName,
        [Parameter(Mandatory)] [string]$MappingRuleName,
        [string]$SourceName      = 'clickstream-source',
        [string]$DestinationName = 'clickstream-eventhouse',
        [string]$StreamName      = 'clickstream-stream',
        [string]$Description     = ''
    )

    $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/eventstreams").Body
    $existing = $list.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    $esId = $null
    if ($existing) {
        Write-Verbose "Eventstream '$Name' exists (id=$($existing.id))"
        $esId = $existing.id
    }
    else {
        $suffix = -join ((48..57) + (97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
        $connName = "es-eh-conn-$suffix"
        $topology = @{
            sources = @(
                @{ name = $SourceName; type = 'CustomEndpoint'; properties = @{} }
            )
            destinations = @(
                @{ name = $DestinationName; type = 'Eventhouse'
                   properties = @{
                       dataIngestionMode = 'DirectIngestion'
                       workspaceId       = $WorkspaceId
                       itemId            = $KqlDatabaseItemId
                       tableName         = $TableName
                       connectionName    = $connName
                       mappingRuleName   = $MappingRuleName
                   }
                   inputNodes = @(@{ name = $StreamName }) }
            )
            streams = @(
                @{ name = $StreamName; type = 'DefaultStream'; properties = @{}
                   inputNodes = @(@{ name = $SourceName }) }
            )
            operators = @()
            compatibilityLevel = '1.1'
        }
        $esJson = $topology | ConvertTo-Json -Depth 20 -Compress
        $platform = @{
            '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
            metadata  = @{ type = 'Eventstream'; displayName = $Name; description = $Description }
            config    = @{ version = '2.0'; logicalId = '00000000-0000-0000-0000-000000000000' }
        } | ConvertTo-Json -Depth 8 -Compress

        $body = @{
            displayName = $Name
            type        = 'Eventstream'
            description = $Description
            definition  = @{
                parts = @(
                    @{ path = 'eventstream.json'
                       payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($esJson))
                       payloadType = 'InlineBase64' }
                    @{ path = '.platform'
                       payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($platform))
                       payloadType = 'InlineBase64' }
                )
            }
        }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/items" -Body $body
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create eventstream $Name" | Out-Null
        }
        $list = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/eventstreams").Body
        $created = $list.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
        if (-not $created) { throw "Eventstream '$Name' was not created" }
        $esId = $created.id
    }

    # Resume the eventstream (newly-created streams stay paused until started)
    try {
        $resumeBody = '{"startType":"Now"}'
        $hdr = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
        Invoke-WebRequest -Method POST `
            -Uri "$script:FabricApiBase/workspaces/$WorkspaceId/eventstreams/$esId/resume" `
            -Headers $hdr -Body $resumeBody -SkipHttpErrorCheck | Out-Null
    } catch {
        Write-Warning "Eventstream resume failed (non-fatal): $_"
    }

    $topology = (Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/eventstreams/$esId/topology").Body
    $src = $topology.sources | Select-Object -First 1
    $dst = $topology.destinations | Select-Object -First 1
    return @{
        eventstreamId   = $esId
        sourceId        = $src.id
        sourceName      = $src.name
        destinationId   = $dst.id
        connectionName  = $dst.properties.connectionName
    }
}

function Get-FabricEventstreamSourceConnectionString {
    <#
    .SYNOPSIS
        Returns the EH-compatible SAS connection string for a CustomEndpoint
        source on an Eventstream. Use this to seed the Function app's
        EVENTHUB_CONNECTION_STRING setting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$EventstreamId,
        [Parameter(Mandatory)] [string]$SourceId
    )
    # Right after eventstream creation the backing EH authorization rule
    # can take 10-60s to materialize; until then this endpoint returns 404
    # AuthorizationRuleNotFound. Retry quietly.
    $maxAttempts = 12
    $r = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $r = (Invoke-FabricRest -Token $Token -Method GET `
                -Path "/workspaces/$WorkspaceId/eventstreams/$EventstreamId/sources/$SourceId/connection").Body
            if ($attempt -gt 1) { Write-Host "    source connection ready on attempt $attempt" -ForegroundColor DarkGray }
            break
        } catch {
            if ($attempt -eq $maxAttempts) { throw }
            if ($_.Exception.Message -match '404|AuthorizationRuleNotFound') {
                Write-Host "    source connection not yet provisioned; waiting 10s (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
                Start-Sleep -Seconds 10
            } else {
                throw
            }
        }
    }
    if (-not $r.accessKeys.primaryConnectionString) {
        throw "Source connection response missing accessKeys.primaryConnectionString"
    }
    return $r.accessKeys.primaryConnectionString
}

# -----------------------------------------------------------------------------
# Semantic Models (TMDL)
# -----------------------------------------------------------------------------

function New-FabricSemanticModel {
    <#
    .SYNOPSIS
        Creates (or updates) a Fabric Semantic Model from a local TMDL
        definition folder (.platform + definition.pbism + definition/*.tmdl).
    .DESCRIPTION
        Walks $DefinitionRoot, base64-encodes every file (except .platform,
        which is git-integration metadata only), applies optional text
        $Replacements to .tmdl / .pbism payloads, and POSTs as a Fabric
        Semantic Model item. Idempotent: if a model with the same name
        already exists in the workspace, its definition is updated in place.
    .PARAMETER DefinitionRoot
        Local folder containing the model project (e.g. sm_retail_sales/).
        Must contain definition/ subfolder with database.tmdl + model.tmdl.
    .PARAMETER Replacements
        Hashtable of literal token -> value pairs applied to each text part
        before upload. Used to inject the warehouse SQL endpoint + db name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DefinitionRoot,
        [hashtable]$Replacements,
        [string]$FolderId
    )
    if (-not (Test-Path $DefinitionRoot)) {
        throw "Semantic model definition root not found: $DefinitionRoot"
    }

    $rootFull = (Resolve-Path $DefinitionRoot).Path
    $files = Get-ChildItem -Path $rootFull -Recurse -File |
        Where-Object { $_.Name -ne '.platform' }

    $parts = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\','/').Replace('\','/')
        $isText = $f.Extension -in @('.tmdl', '.pbism', '.json')
        if ($isText) {
            $text = Get-Content -Raw -Path $f.FullName
            if ($Replacements) {
                foreach ($k in $Replacements.Keys) {
                    $text = $text.Replace($k, [string]$Replacements[$k])
                }
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        }
        $parts += @{
            path        = $rel
            payload     = [Convert]::ToBase64String($bytes)
            payloadType = 'InlineBase64'
        }
    }

    $definition = @{ parts = $parts }

    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/semanticModels"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1

    if ($existing) {
        Write-Verbose "Semantic model '$Name' exists (id=$($existing.id)); updating definition."
        $body = @{ definition = $definition }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/semanticModels/$($existing.id)/updateDefinition" -Body $body
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "update semantic model $Name" | Out-Null
        }
        return $existing
    }

    $body = @{
        displayName = $Name
        definition  = $definition
    }
    if ($FolderId) { $body.folderId = $FolderId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/semanticModels" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create semantic model $Name" | Out-Null
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/semanticModels"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}




function New-FabricReport {
    <#
    .SYNOPSIS
        Creates (or updates) a Fabric Report from a local PBIR-Legacy definition
        folder (.platform + definition.pbir + report.json).
    .DESCRIPTION
        Same upload pattern as New-FabricSemanticModel: walks $DefinitionRoot,
        base64-encodes every file (skipping .platform), applies optional text
        $Replacements to text payloads, and POSTs as a Fabric Report item.
        Idempotent against report display name. Use $Replacements to inject
        __SEMANTIC_MODEL_ID__ into definition.pbir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DefinitionRoot,
        [hashtable]$Replacements,
        [string]$FolderId
    )
    if (-not (Test-Path $DefinitionRoot)) {
        throw "Report definition root not found: $DefinitionRoot"
    }

    $rootFull = (Resolve-Path $DefinitionRoot).Path
    $files = Get-ChildItem -Path $rootFull -Recurse -File |
        Where-Object { $_.Name -ne '.platform' }

    $parts = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\','/').Replace('\','/')
        $isText = $f.Extension -in @('.pbir', '.json')
        if ($isText) {
            $text = Get-Content -Raw -Path $f.FullName
            if ($Replacements) {
                foreach ($k in $Replacements.Keys) {
                    $text = $text.Replace($k, [string]$Replacements[$k])
                }
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        }
        $parts += @{
            path        = $rel
            payload     = [Convert]::ToBase64String($bytes)
            payloadType = 'InlineBase64'
        }
    }

    $definition = @{ parts = $parts }

    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/reports"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1

    if ($existing) {
        Write-Verbose "Report '$Name' exists (id=$($existing.id)); updating definition."
        $body = @{ definition = $definition }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/reports/$($existing.id)/updateDefinition" -Body $body
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "update report $Name" | Out-Null
        }
        return $existing
    }

    $body = @{
        displayName = $Name
        definition  = $definition
    }
    if ($FolderId) { $body.folderId = $FolderId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/reports" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create report $Name" | Out-Null
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/reports"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

function New-FabricReport {
    <#
    .SYNOPSIS
        Creates (or updates) a Fabric Report from a local PBIR-Legacy definition
        folder (.platform + definition.pbir + report.json).
    .DESCRIPTION
        Same upload pattern as New-FabricSemanticModel: walks $DefinitionRoot,
        base64-encodes every file (skipping .platform), applies optional text
        $Replacements to text payloads, and POSTs as a Fabric Report item.
        Idempotent against report display name. Use $Replacements to inject
        __SEMANTIC_MODEL_ID__ into definition.pbir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DefinitionRoot,
        [hashtable]$Replacements,
        [string]$FolderId
    )
    if (-not (Test-Path $DefinitionRoot)) {
        throw "Report definition root not found: $DefinitionRoot"
    }

    $rootFull = (Resolve-Path $DefinitionRoot).Path
    $files = Get-ChildItem -Path $rootFull -Recurse -File |
        Where-Object { $_.Name -ne '.platform' }

    $parts = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\','/').Replace('\','/')
        $isText = $f.Extension -in @('.pbir', '.json')
        if ($isText) {
            $text = Get-Content -Raw -Path $f.FullName
            if ($Replacements) {
                foreach ($k in $Replacements.Keys) {
                    $text = $text.Replace($k, [string]$Replacements[$k])
                }
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        }
        $parts += @{
            path        = $rel
            payload     = [Convert]::ToBase64String($bytes)
            payloadType = 'InlineBase64'
        }
    }

    $definition = @{ parts = $parts }

    $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/reports"
    $existing = $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1

    if ($existing) {
        Write-Verbose "Report '$Name' exists (id=$($existing.id)); updating definition."
        $body = @{ definition = $definition }
        $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/reports/$($existing.id)/updateDefinition" -Body $body
        if ($r.Status -eq 202 -and $r.OperationLocation) {
            Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "update report $Name" | Out-Null
        }
        return $existing
    }

    $body = @{
        displayName = $Name
        definition  = $definition
    }
    if ($FolderId) { $body.folderId = $FolderId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/reports" -Body $body
    if ($r.Status -eq 202 -and $r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label "create report $Name" | Out-Null
        $list = Invoke-FabricRest -Token $Token -Method GET -Path "/workspaces/$WorkspaceId/reports"
        return $list.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
    }
    return $r.Body
}

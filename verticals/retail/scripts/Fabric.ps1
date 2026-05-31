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

    try {
        $resp = Invoke-RestMethod @params
    }
    catch {
        # Surface the response body if present for easier debugging
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errMsg += "`nResponse: $($_.ErrorDetails.Message)"
        }
        throw "Fabric API $Method $Path failed: $errMsg"
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
        [Parameter(Mandatory)] [string]$NotebookPath
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
        [hashtable]$Replacements
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
    $r = (Invoke-FabricRest -Token $Token -Method GET `
        -Path "/workspaces/$WorkspaceId/eventstreams/$EventstreamId/sources/$SourceId/connection").Body
    if (-not $r.accessKeys.primaryConnectionString) {
        throw "Source connection response missing accessKeys.primaryConnectionString"
    }
    return $r.accessKeys.primaryConnectionString
}

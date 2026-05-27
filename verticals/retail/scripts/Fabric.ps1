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
        [int]$PollSeconds   = 15
    )

    $body = $null
    if ($Parameters -and $Parameters.Count -gt 0) {
        $body = @{
            executionData = @{
                parameters = $Parameters
            }
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST `
        -Path "/workspaces/$WorkspaceId/items/$NotebookId/jobs/instances?jobType=RunNotebook" `
        -Body $body

    # Job creation returns 202 + Location header pointing at the job instance.
    if (-not $r.OperationLocation) {
        throw "Notebook run did not return an operation location (status=$($r.Status))"
    }

    Write-Verbose "Polling notebook job at $($r.OperationLocation)"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ((Get-Date) -gt $deadline) {
            throw "Notebook run timed out after $TimeoutSeconds s"
        }
        $status = Invoke-FabricRest -Token $Token -Method GET -Path $r.OperationLocation
        $s = $status.Body.status
        if ($s -in @('Completed','Succeeded')) {
            return $status.Body
        }
        if ($s -in @('Failed','Cancelled','Deduped')) {
            $detail = $status.Body | ConvertTo-Json -Depth 10
            throw "Notebook run finished with status '$s': $detail"
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# -----------------------------------------------------------------------------
# Mirrored Database (Azure SQL -> bronze lakehouse via change feed)
# -----------------------------------------------------------------------------

function New-FabricMirroredAzureSqlDatabase {
    <#
    .SYNOPSIS
        Creates a Mirrored Database item that replicates the given Azure SQL DB
        into the workspace. Mirroring takes a one-time snapshot, then streams
        changes via CDC. Best created AFTER the source DB has data so the
        initial snapshot is meaningful.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$SqlServerFqdn,
        [Parameter(Mandatory)] [string]$DatabaseName
    )

    # Mirror definition - tells Fabric what to mirror and how to authenticate.
    # We mirror ALL tables; refine later via the Fabric portal if needed.
    $mirroringJson = @{
        properties = @{
            source = @{
                type = 'AzureSqlDatabase'
                typeProperties = @{
                    endpoint = "$SqlServerFqdn,1433"
                    database = $DatabaseName
                }
            }
            target = @{
                type = 'MountedRelationalDatabase'
                typeProperties = @{
                    defaultSchema = 'dbo'
                    format        = 'Delta'
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

    # Start mirroring
    if ($created) {
        Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/mirroredDatabases/$($created.id)/startMirroring" | Out-Null
    }
    return $created
}

# -----------------------------------------------------------------------------
# OneLake Shortcut (ADLS Gen2 -> bronze lakehouse Files area)
# -----------------------------------------------------------------------------

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
        [string]$SubPath = ''
    )

    $location = "https://$StorageAccountName.dfs.core.windows.net"
    $subPath  = if ($SubPath) { "/$Container/$($SubPath.TrimStart('/'))" } else { "/$Container" }

    $body = @{
        path   = 'Files'
        name   = $ShortcutName
        target = @{
            adlsGen2 = @{
                location          = $location
                subpath           = $subPath
                connectionId      = $null   # use the caller's identity (workspace identity / user)
            }
        }
    }

    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/items/$LakehouseId/shortcuts" -Body $body
    return $r.Body
}

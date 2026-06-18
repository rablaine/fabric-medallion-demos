# =============================================================================
# Fabric.ps1 - Helper functions for the Microsoft Fabric REST API (healthcare)
# =============================================================================
# Dot-source from deploy.ps1:   . "$PSScriptRoot\scripts\Fabric.ps1"
#
# Trimmed copy of the retail vertical's helper - only the pieces the healthcare
# deploy needs: token acquisition (+ silent/interactive refresh on 401),
# a resilient REST wrapper, capacity GUID lookup, and workspace create/assign.
#
# Reference: https://learn.microsoft.com/rest/api/fabric/
# =============================================================================

$script:FabricApiBase  = 'https://api.fabric.microsoft.com/v1'
$script:FabricTenantId = ''
$script:FabricToken    = ''

function Set-FabricTenant {
    # Register tenant id so token refresh can run 'az login --tenant <X>' if both
    # the access token and the cached refresh token die mid-deploy.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)
    $script:FabricTenantId = $TenantId
}

function Get-FabricToken {
    $json = az account get-access-token --resource 'https://api.fabric.microsoft.com' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Failed to obtain Fabric API access token. Are you logged in (az login)?"
    }
    $tok = ($json | ConvertFrom-Json).accessToken
    $script:FabricToken = $tok
    return $tok
}

function Get-FreshFabricToken {
    # Silent refresh first (cached refresh token), interactive az login if that
    # fails too, so a long deploy crossing the ~1hr token TTL doesn't restart.
    $json = az account get-access-token --resource 'https://api.fabric.microsoft.com' --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($json)) {
        $tok = ($json | ConvertFrom-Json).accessToken
        $script:FabricToken = $tok
        return $tok
    }
    if (-not $script:FabricTenantId) {
        throw "Fabric token expired and silent refresh failed; tenant not registered (call Set-FabricTenant)."
    }
    Write-Host "    [!] Fabric token expired; launching 'az login --tenant $script:FabricTenantId'..." -ForegroundColor Yellow
    az login --tenant $script:FabricTenantId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "az login failed; cannot continue." }
    $json = az account get-access-token --resource 'https://api.fabric.microsoft.com' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Could not acquire Fabric access token even after re-login."
    }
    $tok = ($json | ConvertFrom-Json).accessToken
    $script:FabricToken = $tok
    return $tok
}

function Invoke-FabricRest {
    <#
    .SYNOPSIS
        Invoke-RestMethod wrapper with auth, JSON body, 401 refresh, transient
        retry, and LRO header capture. Returns @{ Status; Body; OperationLocation }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PATCH','PUT','DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,   # e.g. /workspaces  (leading slash optional)
        [object]$Body
    )

    $uri = if ($Path.StartsWith('http')) { $Path } else { "$($script:FabricApiBase)/$($Path.TrimStart('/'))" }
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }

    $params = @{
        Method                  = $Method
        Uri                     = $uri
        Headers                 = $headers
        ErrorAction             = 'Stop'
        ResponseHeadersVariable = 'respHeaders'
        StatusCodeVariable      = 'respStatus'
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 50 -Compress) }

    $maxAttempts       = 8
    $maxTokenRefreshes = 2
    $tokenRefreshes    = 0
    $resp = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $resp = Invoke-RestMethod @params
            break
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $errMsg += "`nResponse: $($_.ErrorDetails.Message)" }

            $isTokenExpired = ($respStatus -eq 401) -or ($errMsg -match 'TokenExpired|Access token has expired|401 \(Unauthorized\)')
            if ($isTokenExpired -and $tokenRefreshes -lt $maxTokenRefreshes) {
                $tokenRefreshes++
                Write-Host "  Fabric API $Method ${Path}: token expired (refresh $tokenRefreshes/$maxTokenRefreshes); re-acquiring..." -ForegroundColor DarkYellow
                $newTok = Get-FreshFabricToken
                $headers.Authorization = "Bearer $newTok"
                $attempt--
                continue
            }

            $isTransient = ($respStatus -in 429, 500, 502, 503, 504) -or `
                ($errMsg -match 'unexpected EOF|SSL connection could not be established|actively refused|operation has timed out|underlying connection was closed|forcibly closed by the remote host|Unable to read data from the transport connection|error occurred while sending the request|connection was aborted|temporary failure in name resolution')
            if (-not $isTransient -or $attempt -eq $maxAttempts) {
                throw "Fabric API $Method $Path failed: $errMsg"
            }
            $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt))
            if ($respStatus -eq 429) {
                $retryAfter = $null
                try { $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch {}
                if ($retryAfter) { $delay = [int]$retryAfter } else { $delay = [int][Math]::Min(120, 15 * $attempt) }
            }
            Write-Host "  Fabric API $Method $Path transient error (attempt $attempt/$maxAttempts); retry in ${delay}s." -ForegroundColor DarkYellow
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
    return @{ Status = $respStatus; Body = $resp; OperationLocation = $opLoc }
}

function Get-FabricCapacityGuid {
    <#
    .SYNOPSIS
        Bicep returns the ARM id; the Fabric REST API needs the capacity GUID.
        Look it up by displayName via GET /capacities.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$CapacityName
    )
    $r = Invoke-FabricRest -Token $Token -Method GET -Path '/capacities'
    $cap = $r.Body.value | Where-Object { $_.displayName -eq $CapacityName } | Select-Object -First 1
    if (-not $cap) {
        throw "Fabric capacity '$CapacityName' not visible in the tenant yet (still provisioning?)."
    }
    return $cap.id
}

function Get-FabricWorkspaceByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Name
    )
    $r = Invoke-FabricRest -Token $Token -Method GET -Path '/workspaces'
    return $r.Body.value | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
}

function Set-FabricWorkspaceCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$WorkspaceId,
        [Parameter(Mandatory)] [string]$CapacityId
    )
    $body = @{ capacityId = $CapacityId }
    Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/assignToCapacity" -Body $body | Out-Null
}

function New-FabricWorkspace {
    <#
    .SYNOPSIS
        Creates a workspace bound to the given capacity GUID (or returns the
        existing one with the same displayName, re-binding it if needed).
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
        if ($existing.capacityId -ne $CapacityId) {
            Set-FabricWorkspaceCapacity -Token $Token -WorkspaceId $existing.id -CapacityId $CapacityId
        }
        return $existing
    }
    $body = @{ displayName = $Name; description = $Description; capacityId = $CapacityId }
    $r = Invoke-FabricRest -Token $Token -Method POST -Path '/workspaces' -Body $body
    return $r.Body
}

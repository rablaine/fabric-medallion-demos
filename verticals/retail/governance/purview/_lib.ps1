# Shared helpers for all Purview scripts. Dot-source: . "$PSScriptRoot\_lib.ps1"

$ErrorActionPreference = 'Stop'

function Get-PurviewToken {
    # Purview data-plane scope
    return (az account get-access-token --resource https://purview.azure.net --query accessToken -o tsv)
}

function Get-ArmToken {
    return (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
}

function Get-FabricToken {
    return (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
}

function Invoke-PurviewRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','PUT','POST','DELETE','PATCH')] [string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [object]$Body,
        [hashtable]$ExtraHeaders,
        [int]$MaxRetries = 5
    )
    $tok = Get-PurviewToken
    $headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    $jsonBody = $null
    if ($null -ne $Body) {
        if ($Body -is [string]) { $jsonBody = $Body } else { $jsonBody = $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if ($jsonBody) {
                return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $jsonBody
            } else {
                return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers
            }
        } catch {
            $sc = $null
            try { $sc = $_.Exception.Response.StatusCode.value__ } catch {}
            if ($sc -eq 429 -and $attempt -lt $MaxRetries) {
                $wait = [Math]::Pow(2, $attempt)
                Write-Host "    throttled (429); sleep $wait s (attempt $attempt/$MaxRetries)" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            if ($sc -eq 404) { return $null }  # let callers treat as "doesn't exist"
            throw
        }
    }
}

# Drop-in retry wrapper for Invoke-RestMethod. Same signature for common params
# so callers can do a literal swap. Retries 408/429/500/502/503/504 plus the
# usual transient network-layer errors (Front Door OriginConnectionAborted,
# socket resets, DNS hiccups). Exponential backoff capped at 30 s.
function Invoke-RestWithRetry {
    [CmdletBinding()]
    param(
        [string]$Method = 'Get',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [object]$Body,
        [string]$ContentType,
        [int]$MaxRetries = 6,
        [switch]$SkipHttpErrorCheck
    )
    $forward = @{}
    foreach ($k in 'Method','Uri','Headers','Body','ContentType','SkipHttpErrorCheck') {
        if ($PSBoundParameters.ContainsKey($k)) { $forward[$k] = $PSBoundParameters[$k] }
    }
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return Invoke-RestMethod @forward
        } catch {
            $sc = $null
            try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
            $msg = "$($_.Exception.Message)"
            $isTransient = ($sc -in 408,429,500,502,503,504) -or `
                ($msg -match 'forcibly closed|connection was aborted|connection was closed|timed out|Service Unavailable|Bad Gateway|Gateway Timeout|could not be resolved|temporary failure in name resolution|OriginConnectionAborted|service behind this page|target machine actively refused')
            if ($isTransient -and $attempt -lt $MaxRetries) {
                $wait = [int][Math]::Min([Math]::Pow(2, $attempt), 30)
                $label = if ($sc) { "status=$sc" } else { 'network' }
                Write-Host "    transient REST error ($label); sleep ${wait}s (attempt $attempt/$MaxRetries)" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

function Read-Context {
    param([string]$Path = "$PSScriptRoot\context.json")
    if (-not (Test-Path $Path)) { throw "Context file not found: $Path. Run 00-discover.ps1 first." }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

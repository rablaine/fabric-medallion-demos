# Phase 16: apply self-service access policies to glossary terms.
#
# Endpoint (tenant-flavored host, NOT account endpoint):
#   PUT    https://{tenantId}-api.purview-service.microsoft.com/datagovernance/dataaccess/terms/{termId}/policySets/applied?api-version=2023-10-01-preview
#   GET    same URL -> 200 + body if policy exists, 204 if not
#   DELETE same URL -> 204
#
# Body shape (term targets):
#   {
#     "policies": {
#       "dataCopyPermitted": <bool>,
#       "managerApprovalRequired": <bool>,        (optional; defaults false)
#       "attestations": [
#         { "displayName": "...", "documentReference": "https://...", "required": <bool> }
#       ]
#     }
#   }
#
# Token: standard Purview data-plane (https://purview.azure.net).
# Idempotency: PUT is upsert. We GET first; skip if the existing policy matches our spec.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

if (-not $ctx.tenantId)      { throw "Missing tenantId in context.json. Run 00-discover.ps1." }
if (-not $ctx.glossaryTerms) { throw "Run 12-glossary-terms.ps1 first." }

$tenantApi = "https://$($ctx.tenantId)-api.purview-service.microsoft.com"
$apiVer    = '2023-10-01-preview'

# Term-name -> id lookup
$termIdByName = @{}
foreach ($t in $ctx.glossaryTerms) { $termIdByName[$t.name] = $t.id }

# Policy specs. Mix of retail + HR so demo shows both consumer-data and employee-data scenarios.
$specs = @(
  [pscustomobject]@{
    Term     = 'Customer'
    Policies = @{
      dataCopyPermitted       = $false
      managerApprovalRequired = $false
      attestations = @(
        @{ displayName = 'Contoso Customer Data Use Agreement'; documentReference = 'https://contoso.com/policies/customer-data-use'; required = $true }
      )
    }
  },
  [pscustomobject]@{
    Term     = 'Sale'
    Policies = @{
      dataCopyPermitted       = $true
      managerApprovalRequired = $false
      attestations = @(
        @{ displayName = 'Sales Data Internal Use Policy'; documentReference = 'https://contoso.com/policies/sales-internal-use'; required = $true }
      )
    }
  },
  [pscustomobject]@{
    Term     = 'Employee'
    Policies = @{
      dataCopyPermitted       = $false
      managerApprovalRequired = $true
      attestations = @(
        @{ displayName = 'HR Confidentiality Acknowledgement'; documentReference = 'https://contoso.com/policies/hr-confidentiality';     required = $true }
        @{ displayName = 'GDPR Personal Data Handling';        documentReference = 'https://contoso.com/policies/gdpr-personal-data';      required = $true }
      )
    }
  }
)

$tok = Get-PurviewToken
$h   = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

function Test-PolicyMatches {
    param($Existing, $Spec)
    if (-not $Existing -or -not $Existing.policies) { return $false }
    $e = $Existing.policies
    $s = $Spec
    if ([bool]$e.dataCopyPermitted       -ne [bool]$s.dataCopyPermitted)       { return $false }
    if ([bool]$e.managerApprovalRequired -ne [bool]$s.managerApprovalRequired) { return $false }
    $eAtt = @($e.attestations)
    $sAtt = @($s.attestations)
    if ($eAtt.Count -ne $sAtt.Count) { return $false }
    foreach ($a in $sAtt) {
        $match = $eAtt | Where-Object {
            $_.displayName       -eq $a.displayName -and
            $_.documentReference -eq $a.documentReference -and
            [bool]$_.required    -eq [bool]$a.required
        }
        if (-not $match) { return $false }
    }
    return $true
}

$applied = @()
foreach ($spec in $specs) {
    $termId = $termIdByName[$spec.Term]
    if (-not $termId) {
        Write-Warning "Term '$($spec.Term)' not in context.json, skipping"
        continue
    }
    $url = "$tenantApi/datagovernance/dataaccess/terms/$termId/policySets/applied?api-version=$apiVer"

    # GET current state
    $existing = $null
    $get = Invoke-WebRequest -Uri $url -Headers $h -SkipHttpErrorCheck
    if ($get.StatusCode -eq 200 -and $get.RawContentStream.Length) {
        $existing = [System.Text.Encoding]::UTF8.GetString($get.RawContentStream.ToArray()) | ConvertFrom-Json
    } elseif ($get.StatusCode -notin 200,204) {
        $bodyTxt = if ($get.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($get.RawContentStream.ToArray()) } else { '' }
        throw "GET $url failed: $($get.StatusCode) $bodyTxt"
    }

    if (Test-PolicyMatches -Existing $existing -Spec $spec.Policies) {
        Write-Host "[exists] '$($spec.Term)' policy unchanged (policySetId=$($existing.policySetId))" -ForegroundColor DarkGray
        $applied += [ordered]@{ term = $spec.Term; termId = $termId; policySetId = $existing.policySetId }
        continue
    }

    $body = @{ policies = $spec.Policies } | ConvertTo-Json -Depth 8
    $put  = Invoke-WebRequest -Method PUT -Uri $url -Headers $h -Body $body -SkipHttpErrorCheck
    if ($put.StatusCode -notin 200,201) {
        $bodyTxt = if ($put.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($put.RawContentStream.ToArray()) } else { '' }
        throw "PUT $url failed: $($put.StatusCode) $bodyTxt"
    }
    $resp = [System.Text.Encoding]::UTF8.GetString($put.RawContentStream.ToArray()) | ConvertFrom-Json
    $verb = if ($existing) { '[updated]' } else { '[created]' }
    Write-Host "$verb '$($spec.Term)' policy (policySetId=$($resp.policySetId), $($spec.Policies.attestations.Count) attestation(s))" -ForegroundColor Green
    $applied += [ordered]@{ term = $spec.Term; termId = $termId; policySetId = $resp.policySetId }
}

# Persist to context.json
if ($ctx.PSObject.Properties['accessPolicies']) { $ctx.PSObject.Properties.Remove('accessPolicies') }
$ctx | Add-Member -NotePropertyName accessPolicies -NotePropertyValue $applied
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. $($applied.Count) access policies in context.json."

# Phase 17: data-product access policies + approval workflows.
#
# Endpoints (tenant-flavored host, NOT account endpoint):
#   GET    /datagovernance/dataaccess/workflows
#            -> { results: [ { id, name, triggers[{underGlossaryHierarchy}], ... }, ... ] }
#   PUT    /datagovernance/dataaccess/workflows/{newGuid}
#            -> 201, workflow with DAG (manager approval + privacy + data approvers + ApproveDataSubscription)
#   GET    /datagovernance/dataaccess/dataProducts/{dpId}/policySets/applied?api-version=2023-10-01-preview
#            -> 200 + body, or 204
#   PUT    /datagovernance/dataaccess/dataProducts/{dpId}/policySets/applied?api-version=2023-10-01-preview
#            body: { policies: { approvers, permittedUseCases, managerApprovalRequired,
#                                 privacyComplianceApprovalRequired, dataCopyPermitted,
#                                 attestations[], skipWorkflow, maximumAccessDuration } }
#
# permittedUseCases is NOT an enum string — it's free-form [{ title, description }] objects.
# approvers entry shape: { identityType:'User', objectId, tenantId }.
# maximumAccessDuration: { durationType:'Years'|'Months'|'Days'; length:int }.
#
# Token: standard https://purview.azure.net audience.
# Idempotency: skip if workflow already scoped to this DP; skip if DP policy already exists.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

if (-not $ctx.tenantId)     { throw "Missing tenantId. Run 00-discover.ps1." }
if (-not $ctx.dataProducts) { throw "Run 13-data-products.ps1 first." }

$tenantApi = "https://$($ctx.tenantId)-api.purview-service.microsoft.com"
$apiVer    = '2023-10-01-preview'

$ownerId = (az ad signed-in-user show --query id -o tsv)
if (-not $ownerId) { throw "Could not resolve signed-in user objectId" }

# DP lookup
$dpByName = @{}
foreach ($dp in $ctx.dataProducts) { $dpByName[$dp.name] = $dp.id }

# Per-DP policy specs. Differentiated so the demo shows variety in the UC portal.
$specs = @(
  [pscustomobject]@{
    DpName = 'Sales'
    Policy = @{
      managerApprovalRequired           = $false
      privacyComplianceApprovalRequired = $false
      dataCopyPermitted                 = $true
      skipWorkflow                      = $false
      maximumAccessDuration             = @{ durationType = 'Years'; length = 1 }
      permittedUseCases = @(
        @{ title = 'Sales Performance Reporting'; description = 'Weekly/monthly comp-store, category, and channel revenue analysis' }
        @{ title = 'Forecasting & Planning';      description = 'Demand forecasting and S&OP inputs' }
        @{ title = 'Promotion Effectiveness';     description = 'Measure lift and ROI of marketing campaigns and promotions' }
      )
      attestations = @(
        @{ displayName = 'Sales Data Internal Use Policy'; documentReference = 'https://contoso.com/policies/sales-internal-use'; required = $true }
      )
    }
  },
  [pscustomobject]@{
    DpName = 'Customer 360'
    Policy = @{
      managerApprovalRequired           = $true
      privacyComplianceApprovalRequired = $true
      dataCopyPermitted                 = $false
      skipWorkflow                      = $false
      maximumAccessDuration             = @{ durationType = 'Months'; length = 6 }
      permittedUseCases = @(
        @{ title = 'Customer Segmentation';   description = 'Build segments for personalization and lifecycle marketing' }
        @{ title = 'Lifetime Value Modeling'; description = 'Train and score CLV models on aggregated, opted-in customers' }
        @{ title = 'Loyalty Program Insights'; description = 'Analyze loyalty member behavior to improve program design' }
      )
      attestations = @(
        @{ displayName = 'Contoso Customer Data Use Agreement'; documentReference = 'https://contoso.com/policies/customer-data-use'; required = $true }
        @{ displayName = 'GDPR Personal Data Handling';         documentReference = 'https://contoso.com/policies/gdpr-personal-data'; required = $true }
      )
    }
  },
  [pscustomobject]@{
    DpName = 'Inventory'
    Policy = @{
      managerApprovalRequired           = $true
      privacyComplianceApprovalRequired = $false
      dataCopyPermitted                 = $true
      skipWorkflow                      = $false
      maximumAccessDuration             = @{ durationType = 'Years'; length = 2 }
      permittedUseCases = @(
        @{ title = 'Shrink Analysis';      description = 'Identify root causes of inventory shrink by SKU and store' }
        @{ title = 'Stockout Reduction';   description = 'Predict and prevent stockouts on high-velocity SKUs' }
        @{ title = 'Assortment Planning';  description = 'Optimize SKU mix and store-level assortment' }
      )
      attestations = @()
    }
  },
  [pscustomobject]@{
    DpName = 'Workforce'
    Policy = @{
      managerApprovalRequired           = $true
      privacyComplianceApprovalRequired = $true
      dataCopyPermitted                 = $false
      skipWorkflow                      = $false
      maximumAccessDuration             = @{ durationType = 'Months'; length = 3 }
      permittedUseCases = @(
        @{ title = 'Attrition Analysis';     description = 'Identify drivers of voluntary attrition by role, tenure, region' }
        @{ title = 'Workforce Planning';     description = 'Headcount and staffing models for store operations' }
        @{ title = 'DEI Reporting';          description = 'Aggregate diversity, equity, and inclusion metrics' }
      )
      attestations = @(
        @{ displayName = 'HR Confidentiality Acknowledgement'; documentReference = 'https://contoso.com/policies/hr-confidentiality'; required = $true }
        @{ displayName = 'GDPR Personal Data Handling';        documentReference = 'https://contoso.com/policies/gdpr-personal-data'; required = $true }
      )
    }
  }
)

$tok = Get-PurviewToken
$h   = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Standard auto-generated DAG (verbatim from portal). Embedded as a string template
# to avoid ConvertFrom/ConvertTo-Json mangling the deeply nested PSCustomObject tree.
# Placeholders: {{APPROVER_ID}}, {{DP_ID}}, {{DP_NAME}}.
$WORKFLOW_BODY_TEMPLATE = @'
{"type":"DataSubscriptionWebhook","name":"Data Access Workflow - {{DP_NAME}}","description":"Auto-generated workflow for data product {{DP_NAME}}","isEnabled":true,"triggers":[{"type":"DataAccessRequestSubmitted","underGlossaryHierarchy":"dataProducts/{{DP_ID}}","businessDomainId":""}],"actionDag":[{"inputs":{"expressions":[{"leftHandSide":"@{triggerBody()?['systemProperties']?['managerApprovalRequired']}","rightHandSide":"true","equality":"IsEqualTo"}],"actions":[{"inputs":{"approvalType":"PendingOnAny","title":"Approval for data access request","assignedTo":["@{triggerBody()?['systemProperties']?['managerIdentity']}"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_manager_approval"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_manager_approval')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"inputs":{"expressions":[{"leftHandSide":"@triggerBody()?['systemProperties']?['privacyComplianceApprovalRequired']","rightHandSide":"true","equality":"IsEqualTo"}],"actions":[{"inputs":{"approvalType":"PendingOnAny","title":"Privacy Compliance Approval for data access request","assignedTo":["@triggerBody()?['systemProperties']?['privacyComplianceTeamIdentities']"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_privacy_approval"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_privacy_approval')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"inputs":{"approvalType":"PendingOnAny","title":"Approval for data access request","assignedTo":["{{APPROVER_ID}}"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_access_request_approvers"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_access_request_approvers')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"actionType":"ApproveDataSubscription","actionName":"Approve_access_request"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request"}]},"actionType":"Condition","actionName":"Access_request_approvers_condition"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request_from_privacy"}]},"actionType":"Condition","actionName":"Privacy_approval_condition"}],"elseActions":[{"inputs":{"approvalType":"PendingOnAny","title":"Approval for data access request","assignedTo":["{{APPROVER_ID}}"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_access_request_approvers_1"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_access_request_approvers_1')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"actionType":"ApproveDataSubscription","actionName":"Approve_access_request_2"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request_2"}]},"actionType":"Condition","actionName":"Access_request_approvers_condition_2"}]},"actionType":"Condition","actionName":"Check_privacy_approval_required"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request_3"}]},"actionType":"Condition","actionName":"Manager_condition"}],"elseActions":[{"inputs":{"expressions":[{"leftHandSide":"@triggerBody()?['systemProperties']?['privacyComplianceApprovalRequired']","rightHandSide":"true","equality":"IsEqualTo"}],"actions":[{"inputs":{"approvalType":"PendingOnAny","title":"Privacy Compliance Approval for data access request","assignedTo":["@triggerBody()?['systemProperties']?['privacyComplianceTeamIdentities']"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_privacy_approval_1"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_privacy_approval_1')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"inputs":{"approvalType":"PendingOnAny","title":"Approval for data access request","assignedTo":["{{APPROVER_ID}}"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_access_request_approvers_2"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_access_request_approvers_2')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"actionType":"ApproveDataSubscription","actionName":"Approve_access_request_3"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request_4"}]},"actionType":"Condition","actionName":"Access_request_approvers_condition_3"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request_5"}]},"actionType":"Condition","actionName":"Privacy_approval_condition_1"}],"elseActions":[{"inputs":{"approvalType":"PendingOnAny","title":"Approval for data access request","assignedTo":["{{APPROVER_ID}}"]},"actionType":"StartAndWaitForApproval","actionName":"Start_and_wait_for_access_request_approvers_8"},{"inputs":{"expressions":[{"leftHandSide":"@body('Start_and_wait_for_access_request_approvers_8')['outcome']","rightHandSide":"Approved","equality":"IsEqualTo"}],"actions":[{"actionType":"ApproveDataSubscription","actionName":"Approve_access_request_4"}],"elseActions":[{"actionType":"RejectDataSubscription","actionName":"Reject_access_request_6"}]},"actionType":"Condition","actionName":"Access_request_approvers_condition_4"}]},"actionType":"Condition","actionName":"Check_privacy_approval_required_2"}]},"actionType":"Condition","actionName":"Manager_approver_required_condition"}]}
'@

function New-WorkflowBody {
    param([string]$DpId, [string]$DpName, [string]$ApproverId)
    return $WORKFLOW_BODY_TEMPLATE `
        -replace '\{\{DP_ID\}\}',       $DpId `
        -replace '\{\{DP_NAME\}\}',     $DpName `
        -replace '\{\{APPROVER_ID\}\}', $ApproverId
}

# List existing workflows once, index by DP id (parsed from underGlossaryHierarchy)
$wfResp = Invoke-WebRequest -Uri "$tenantApi/datagovernance/dataaccess/workflows" -Headers $h -SkipHttpErrorCheck
if ($wfResp.StatusCode -ne 200) {
    $b = if ($wfResp.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($wfResp.RawContentStream.ToArray()) } else { '' }
    throw "GET workflows failed: $($wfResp.StatusCode) $b"
}
$wfList = ([System.Text.Encoding]::UTF8.GetString($wfResp.RawContentStream.ToArray()) | ConvertFrom-Json).results
$wfByDp = @{}
foreach ($w in $wfList) {
    $trig = $w.triggers[0].underGlossaryHierarchy
    if ($trig -match '^dataProducts/(.+)$') { $wfByDp[$Matches[1]] = $w }
}

$results = @()
foreach ($spec in $specs) {
    $dpId = $dpByName[$spec.DpName]
    if (-not $dpId) {
        Write-Warning "DP '$($spec.DpName)' not in context.json, skipping"
        continue
    }

    # --- Workflow ---
    $wf = $wfByDp[$dpId]
    if ($wf) {
        Write-Host "[exists] workflow for '$($spec.DpName)' id=$($wf.id)" -ForegroundColor DarkGray
        $workflowId = $wf.id
    } else {
        $workflowId = [guid]::NewGuid().Guid
        $wfBody = New-WorkflowBody -DpId $dpId -DpName $spec.DpName -ApproverId $ownerId
        $wfUrl = "$tenantApi/datagovernance/dataaccess/workflows/$workflowId"
        $wfPut = Invoke-WebRequest -Method PUT -Uri $wfUrl -Headers $h -Body $wfBody -SkipHttpErrorCheck
        if ($wfPut.StatusCode -notin 200,201) {
            $b = if ($wfPut.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($wfPut.RawContentStream.ToArray()) } else { '' }
            throw "PUT workflow for '$($spec.DpName)' failed: $($wfPut.StatusCode) $b"
        }
        Write-Host "[created] workflow for '$($spec.DpName)' id=$workflowId" -ForegroundColor Green
    }

    # --- Policy ---
    # NOTE: GET always returns 200 with a default skeleton (stock use cases, empty approvers)
    # even when no policy has been applied. Treat empty-approvers as "no policy of ours yet".
    $polUrl = "$tenantApi/datagovernance/dataaccess/dataProducts/$dpId/policySets/applied?api-version=$apiVer"
    $get = Invoke-WebRequest -Uri $polUrl -Headers $h -SkipHttpErrorCheck
    $existing = $null
    if ($get.StatusCode -eq 200) {
        $j = [System.Text.Encoding]::UTF8.GetString($get.RawContentStream.ToArray()) | ConvertFrom-Json
        if ($j.policies.approvers -and $j.policies.approvers.Count -gt 0) { $existing = $j }
    } elseif ($get.StatusCode -ne 204) {
        $b = if ($get.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($get.RawContentStream.ToArray()) } else { '' }
        throw "GET policy for '$($spec.DpName)' failed: $($get.StatusCode) $b"
    }

    if ($existing) {
        Write-Host "[exists] policy for '$($spec.DpName)' policySetId=$($existing.policySetId)" -ForegroundColor DarkGray
        $policySetId = $existing.policySetId
    } else {
        $policyBody = $spec.Policy.Clone()
        $policyBody['approvers'] = @(
            [ordered]@{ identityType = 'User'; objectId = $ownerId; tenantId = $ctx.tenantId }
        )
        $body = @{ policies = $policyBody } | ConvertTo-Json -Depth 10
        $put = Invoke-WebRequest -Method PUT -Uri $polUrl -Headers $h -Body $body -SkipHttpErrorCheck
        if ($put.StatusCode -notin 200,201) {
            $b = if ($put.RawContentStream.Length) { [System.Text.Encoding]::UTF8.GetString($put.RawContentStream.ToArray()) } else { '' }
            throw "PUT policy for '$($spec.DpName)' failed: $($put.StatusCode) $b"
        }
        $resp = [System.Text.Encoding]::UTF8.GetString($put.RawContentStream.ToArray()) | ConvertFrom-Json
        $policySetId = $resp.policySetId
        Write-Host "[created] policy for '$($spec.DpName)' policySetId=$policySetId ($($spec.Policy.permittedUseCases.Count) use cases, $($spec.Policy.attestations.Count) attestation(s), max=$($spec.Policy.maximumAccessDuration.length) $($spec.Policy.maximumAccessDuration.durationType))" -ForegroundColor Green
    }

    $results += [ordered]@{
        dpId        = $dpId
        dpName      = $spec.DpName
        workflowId  = $workflowId
        policySetId = $policySetId
    }
}

# Persist
if ($ctx.PSObject.Properties['dpAccessPolicies']) { $ctx.PSObject.Properties.Remove('dpAccessPolicies') }
$ctx | Add-Member -NotePropertyName dpAccessPolicies -NotePropertyValue $results
($ctx | ConvertTo-Json -Depth 10) | Set-Content "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ""
Write-Host "Done. $($results.Count) DP access policies (+ workflows) in context.json."

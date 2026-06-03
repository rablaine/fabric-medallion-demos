param([string]$ReportId='0888d898-ace6-41f2-bee3-00e10d91ed3c', [string]$OutDir='C:\dev\Contoso\verticals\retail\tools\_live')
$ErrorActionPreference='Stop'
. (Join-Path 'C:\dev\Contoso\verticals\retail\scripts' 'Fabric.ps1')
$tok = Get-FabricToken
$ws = (Invoke-FabricRest -Token $tok -Method GET -Path '/workspaces').Body.value | Where-Object { $_.displayName -like 'cts-rtl-3-gold-*' } | Select-Object -First 1
$wsId = $ws.id
$r = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$wsId/reports/$ReportId/getDefinition"
if ($r.OperationLocation) {
    Wait-FabricOperation -Token $tok -OperationLocation $r.OperationLocation -Label 'getDefinition' | Out-Null
    $r2 = Invoke-FabricRest -Token $tok -Method GET -Path "$($r.OperationLocation)/result"
    $def = $r2.Body
} else {
    $def = $r.Body
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
foreach ($p in $def.definition.parts) {
    $bytes = [Convert]::FromBase64String($p.payload)
    $text  = [Text.Encoding]::UTF8.GetString($bytes)
    $dest  = Join-Path $OutDir $p.path
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Set-Content -Path $dest -Value $text -Encoding UTF8
    Write-Host "wrote $dest"
}

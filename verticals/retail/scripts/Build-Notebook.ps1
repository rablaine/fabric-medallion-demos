# Build-Notebook.ps1
# Helper to assemble a Jupyter .ipynb from an ordered list of cells.
# Cells: array of @{ type='markdown'|'code'; source=<string> }.
# Writes a normalized notebook (nbformat 4.5) with stable cell ids.

function New-Ipynb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Cells,
        [Parameter(Mandatory)] [string]$OutPath
    )
    $i = 0
    $jsonCells = foreach ($c in $Cells) {
        $i++
        $id = ('cell{0:D4}' -f $i)
        $lines = ($c.source -replace "`r`n", "`n") -split "(?<=`n)"
        $src = @($lines | Where-Object { $_.Length -gt 0 })
        if ($c.type -eq 'markdown') {
            [ordered]@{
                cell_type = 'markdown'
                id        = $id
                metadata  = @{}
                source    = $src
            }
        } else {
            [ordered]@{
                cell_type       = 'code'
                execution_count = $null
                id              = $id
                metadata        = @{}
                outputs         = @()
                source          = $src
            }
        }
    }
    $nb = [ordered]@{
        cells          = @($jsonCells)
        metadata       = @{ language_info = @{ name = 'python' } }
        nbformat       = 4
        nbformat_minor = 5
    }
    $json = $nb | ConvertTo-Json -Depth 10
    Set-Content -Path $OutPath -Value $json -NoNewline -Encoding utf8
}

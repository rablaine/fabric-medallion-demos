# build-reports.ps1
# -----------------------------------------------------------------------------
# Generates PBIR-Legacy report definitions (.platform + definition.pbir +
# report.json) under verticals/retail/fabric/reports/ for the gold-warehouse
# semantic models (Retail Sales + HR & Workforce).
#
# These are the SOURCE artifacts that get deployed via New-FabricReport.
# Re-run this script whenever the report spec (visuals/layout/measures)
# changes; commit the regenerated files.
#
# definition.pbir uses byConnection with a __SEMANTIC_MODEL_ID__ token --
# the deploy script substitutes the live model id at upload time.
# -----------------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$OutRoot = (Join-Path $PSScriptRoot '..' 'fabric' 'reports')
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Helpers -- emit the small JSON shapes that make up a visualContainer
# -----------------------------------------------------------------------------

function _ColumnSelect {
    param([string]$Src, [string]$Property, [string]$Name)
    @{
        Column = @{
            Expression = @{ SourceRef = @{ Source = $Src } }
            Property   = $Property
        }
        Name = $Name
        NativeReferenceName = $Property
    }
}

function _MeasureSelect {
    param([string]$Src, [string]$Property, [string]$Name)
    @{
        Measure = @{
            Expression = @{ SourceRef = @{ Source = $Src } }
            Property   = $Property
        }
        Name = $Name
        NativeReferenceName = $Property
    }
}

function _From {
    param([hashtable[]]$Tables)
    $out = [System.Collections.ArrayList]::new()
    foreach ($t in $Tables) {
        [void]$out.Add(@{ Name = $t.a; Entity = $t.e; Type = 0 })
    }
    # Always return as an array, even for single entry (forces JSON array).
    return ,@($out.ToArray())
}

# -----------------------------------------------------------------------------
# Visual builders -- return a visualContainer hashtable
# -----------------------------------------------------------------------------

function New-CardVisual {
    # Renders a single KPI as a multiRowCard (one row). multiRowCard mirrors
    # the QuickCreate / Auto-create visual shape and renders reliably.
    param(
        [hashtable]$Pos,
        [string]$Title,
        [hashtable]$Measure
    )
    $alias = 'd1'
    $qname = "$($Measure.entity).$($Measure.prop)"
    $proto = @{
        Version = 2
        From    = (_From @(@{a=$alias;e=$Measure.entity}))
        Select  = @(_MeasureSelect -Src $alias -Property $Measure.prop -Name $qname)
    }
    $single = @{
        visualType = 'multiRowCard'
        projections = @{ Values = @(@{ queryRef = $qname }) }
        prototypeQuery = $proto
        drillFilterOtherVisuals = $true
        objects = @{
            card = @(@{ properties = @{
                barColor = @{ solid = @{ color = @{ expr = @{ ThemeDataColor = @{ ColorId = 2; Percent = 0 } } } } }
                barWeight = @{ expr = @{ Literal = @{ Value = '4L' } } }
            } })
            dataLabels = @(@{ properties = @{
                fontFamily = @{ expr = @{ Literal = @{ Value = "'Segoe UI'" } } }
                fontSize   = @{ expr = @{ Literal = @{ Value = '20L' } } }
            } })
            categoryLabels = @(@{ properties = @{
                color = @{ solid = @{ color = @{ expr = @{ ThemeDataColor = @{ ColorId = 1; Percent = 0.4 } } } } }
                fontSize = @{ expr = @{ Literal = @{ Value = '11L' } } }
            } })
        }
    }
    $cfg = @{
        name = ([Guid]::NewGuid().ToString('N').Substring(0,20))
        layouts = @(@{ id = 0; position = @{ x = $Pos.x; y = $Pos.y; z = ($Pos.z ?? 0); width = $Pos.w; height = $Pos.h; tabOrder = 0 } })
        singleVisual = $single
    }
    @{
        config  = ($cfg | ConvertTo-Json -Depth 30 -Compress)
        filters = '[]'
        height  = [double]$Pos.h
        width   = [double]$Pos.w
        x       = [double]$Pos.x
        y       = [double]$Pos.y
        z       = [double]($Pos.z ?? 0)
    }
}

function New-BarChartVisual {
    <# Category on Y axis (horizontal bars). Use $VisualType='clusteredBarChart' or 'clusteredColumnChart'. #>
    param(
        [hashtable]$Pos,
        [string]$Title,
        [hashtable]$Category,          # @{entity;prop}
        [hashtable]$Measure,           # @{entity;prop}
        [string]$VisualType = 'clusteredBarChart',
        [int]$TopN = 0                 # 0 = no limit
    )
    $catAlias  = 'c'
    $measAlias = 'm'
    $catName  = "$($Category.entity).$($Category.prop)"
    $measName = "$($Measure.entity).$($Measure.prop)"
    $from = @( @{a=$catAlias;e=$Category.entity} )
    if ($Category.entity -ne $Measure.entity) { $from += @{a=$measAlias;e=$Measure.entity} }
    else { $measAlias = $catAlias }
    $proto = @{
        Version = 2
        From    = (_From $from)
        Select  = @(
            (_ColumnSelect -Src $catAlias -Property $Category.prop -Name $catName)
            (_MeasureSelect -Src $measAlias -Property $Measure.prop -Name $measName)
        )
        OrderBy = @(@{ Direction = 2; Expression = @{ Measure = @{ Expression = @{ SourceRef = @{ Source = $measAlias } }; Property = $Measure.prop } } })
    }
    # Note: prototypeQuery.Top is forbidden when the visual binding has data
    # reduction (which it always does for clusteredBar/Column). Skip TopN and
    # rely on the visual's own data window / OrderBy to surface top categories.
    $null = $TopN
    $single = @{
        visualType = $VisualType
        projections = @{
            Category = @(@{ queryRef = $catName; active = $true })
            Y        = @(@{ queryRef = $measName })
        }
        prototypeQuery = $proto
        drillFilterOtherVisuals = $true
        hasDefaultSort = $true
    }
    $cfg = @{
        name = ([Guid]::NewGuid().ToString('N').Substring(0,20))
        layouts = @(@{ id = 0; position = @{ x = $Pos.x; y = $Pos.y; z = ($Pos.z ?? 0); width = $Pos.w; height = $Pos.h; tabOrder = 0 } })
        singleVisual = $single
        vcObjects = @{
            title = @(@{ properties = @{
                show = @{ expr = @{ Literal = @{ Value = 'true' } } }
                text = @{ expr = @{ Literal = @{ Value = "'$Title'" } } }
            } })
        }
    }
    @{
        config  = ($cfg | ConvertTo-Json -Depth 30 -Compress)
        filters = '[]'
        height  = [double]$Pos.h
        width   = [double]$Pos.w
        x       = [double]$Pos.x
        y       = [double]$Pos.y
        z       = [double]($Pos.z ?? 0)
    }
}

function New-LineChartVisual {
    param(
        [hashtable]$Pos,
        [string]$Title,
        [hashtable]$Axis,              # @{entity;prop}
        [hashtable]$Measure
    )
    $aAlias = 'a'; $mAlias = 'm'
    $aName = "$($Axis.entity).$($Axis.prop)"
    $mName = "$($Measure.entity).$($Measure.prop)"
    $from = @( @{a=$aAlias;e=$Axis.entity} )
    if ($Axis.entity -ne $Measure.entity) { $from += @{a=$mAlias;e=$Measure.entity} }
    else { $mAlias = $aAlias }
    $proto = @{
        Version = 2
        From    = (_From $from)
        Select  = @(
            (_ColumnSelect -Src $aAlias -Property $Axis.prop -Name $aName)
            (_MeasureSelect -Src $mAlias -Property $Measure.prop -Name $mName)
        )
        OrderBy = @(@{ Direction = 1; Expression = @{ Column = @{ Expression = @{ SourceRef = @{ Source = $aAlias } }; Property = $Axis.prop } } })
    }
    $single = @{
        visualType = 'lineChart'
        projections = @{
            Category = @(@{ queryRef = $aName; active = $true })
            Y        = @(@{ queryRef = $mName })
        }
        prototypeQuery = $proto
        drillFilterOtherVisuals = $true
    }
    $cfg = @{
        name = ([Guid]::NewGuid().ToString('N').Substring(0,20))
        layouts = @(@{ id = 0; position = @{ x = $Pos.x; y = $Pos.y; z = ($Pos.z ?? 0); width = $Pos.w; height = $Pos.h; tabOrder = 0 } })
        singleVisual = $single
        vcObjects = @{
            title = @(@{ properties = @{
                show = @{ expr = @{ Literal = @{ Value = 'true' } } }
                text = @{ expr = @{ Literal = @{ Value = "'$Title'" } } }
            } })
        }
    }
    @{
        config  = ($cfg | ConvertTo-Json -Depth 30 -Compress)
        filters = '[]'
        height  = [double]$Pos.h
        width   = [double]$Pos.w
        x       = [double]$Pos.x
        y       = [double]$Pos.y
        z       = [double]($Pos.z ?? 0)
    }
}

function New-TableVisual {
    param(
        [hashtable]$Pos,
        [string]$Title,
        # @( @{entity;prop;type='col'|'meas'} )
        [hashtable[]]$Fields
    )
    # Stable per-entity aliases so multi-table joins resolve.
    $aliasMap = @{}
    $i = 0
    foreach ($f in $Fields) {
        if (-not $aliasMap.ContainsKey($f.entity)) {
            $aliasMap[$f.entity] = "t$i"
            $i++
        }
    }
    $from = @()
    foreach ($k in $aliasMap.Keys) { $from += @{a=$aliasMap[$k];e=$k} }

    $sel = @()
    $proj = @()
    foreach ($f in $Fields) {
        $alias = $aliasMap[$f.entity]
        $qname = "$($f.entity).$($f.prop)"
        if ($f.type -eq 'meas') {
            $sel += (_MeasureSelect -Src $alias -Property $f.prop -Name $qname)
        } else {
            $sel += (_ColumnSelect -Src $alias -Property $f.prop -Name $qname)
        }
        $proj += @{ queryRef = $qname }
    }
    $proto = @{
        Version = 2
        From    = (_From $from)
        Select  = $sel
    }
    $single = @{
        visualType = 'tableEx'
        projections = @{ Values = $proj }
        prototypeQuery = $proto
        drillFilterOtherVisuals = $true
        objects = @{
            columnHeaders = @(@{ properties = @{
                columnAdjustment = @{ expr = @{ Literal = @{ Value = "'growToFit'" } } }
            } })
        }
    }
    $cfg = @{
        name = ([Guid]::NewGuid().ToString('N').Substring(0,20))
        layouts = @(@{ id = 0; position = @{ x = $Pos.x; y = $Pos.y; z = ($Pos.z ?? 0); width = $Pos.w; height = $Pos.h; tabOrder = 0 } })
        singleVisual = $single
        vcObjects = @{
            title = @(@{ properties = @{
                show = @{ expr = @{ Literal = @{ Value = 'true' } } }
                text = @{ expr = @{ Literal = @{ Value = "'$Title'" } } }
            } })
        }
    }
    @{
        config  = ($cfg | ConvertTo-Json -Depth 30 -Compress)
        filters = '[]'
        height  = [double]$Pos.h
        width   = [double]$Pos.w
        x       = [double]$Pos.x
        y       = [double]$Pos.y
        z       = [double]($Pos.z ?? 0)
    }
}

function New-TextBoxVisual {
    <# Banner / title block. #>
    param([hashtable]$Pos, [string]$Text, [int]$FontSize = 24)
    $textRuns = @(@{ value = $Text; textStyle = @{ fontSize = "$($FontSize)pt"; fontWeight = 'bold' } })
    $paragraphs = @(@{ textRuns = $textRuns })
    $single = @{
        visualType = 'textbox'
        drillFilterOtherVisuals = $true
        objects = @{
            general = @(@{ properties = @{ paragraphs = $paragraphs } })
        }
    }
    $cfg = @{
        name = ([Guid]::NewGuid().ToString('N').Substring(0,20))
        layouts = @(@{ id = 0; position = @{ x = $Pos.x; y = $Pos.y; z = ($Pos.z ?? 0); width = $Pos.w; height = $Pos.h; tabOrder = 0 } })
        singleVisual = $single
    }
    @{
        config  = ($cfg | ConvertTo-Json -Depth 30 -Compress)
        filters = '[]'
        height  = [double]$Pos.h
        width   = [double]$Pos.w
        x       = [double]$Pos.x
        y       = [double]$Pos.y
        z       = [double]($Pos.z ?? 0)
    }
}

# -----------------------------------------------------------------------------
# Page + report builders
# -----------------------------------------------------------------------------

function New-Page {
    param(
        [string]$Name,
        [string]$DisplayName,
        [int]$Ordinal,
        [hashtable[]]$Visuals
    )
    if (-not $Name) { $Name = [Guid]::NewGuid().ToString('N').Substring(0,20) }
    $null = $Ordinal
    @{
        config = '{}'
        displayName = $DisplayName
        displayOption = 1
        filters = '[]'
        height = 720
        name = $Name
        visualContainers = $Visuals
        width = 1280
    }
}

function Save-Report {
    param(
        [string]$Slug,
        [string]$DisplayName,
        [hashtable[]]$Pages
    )

    $reportJson = [ordered]@{
        config = (@{
            version = '5.73'
            themeCollection = @{
                baseTheme = @{
                    name = 'CY26SU05'
                    type = 2
                    version = @{ visual = '2.9.0'; report = '3.3.0'; page = '2.3.1' }
                }
            }
            activeSectionIndex = 0
            defaultDrillFilterOtherVisuals = $true
            settings = @{
                useNewFilterPaneExperience       = $true
                allowChangeFilterTypes           = $true
                useStylableVisualContainerHeader = $true
                queryLimitOption                 = 6
                useEnhancedTooltips              = $true
                exportDataMode                   = 1
                useDefaultAggregateDisplayName   = $true
                allowInlineExploration           = $true
            }
            objects = @{
                section      = @(@{ properties = @{ verticalAlignment = @{ expr = @{ Literal = @{ Value = "'Top'" } } } } })
                outspacePane = @(@{ properties = @{ expanded          = @{ expr = @{ Literal = @{ Value = 'false' } } } } })
            }
        } | ConvertTo-Json -Depth 20 -Compress)
        layoutOptimization = 0
        sections = $Pages
    }

    $platform = [ordered]@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
        metadata = @{ type = 'Report'; displayName = $DisplayName }
        config   = @{ version = '2.0'; logicalId = ([Guid]::NewGuid().ToString()) }
    }
    $pbir = [ordered]@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
        version = '4.0'
        datasetReference = @{
            byConnection = @{
                connectionString = 'semanticmodelid=__SEMANTIC_MODEL_ID__'
            }
        }
    }

    $dir = Join-Path $OutRoot $Slug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $platform | ConvertTo-Json -Depth 10            | Set-Content -Path (Join-Path $dir '.platform')      -Encoding utf8 -NoNewline
    $pbir     | ConvertTo-Json -Depth 10            | Set-Content -Path (Join-Path $dir 'definition.pbir') -Encoding utf8 -NoNewline
    $reportJson | ConvertTo-Json -Depth 50 -Compress | Set-Content -Path (Join-Path $dir 'report.json')    -Encoding utf8 -NoNewline

    Write-Host "  wrote $Slug -> $dir"
}

# =============================================================================
# REPORT 1 -- Retail Sales: Sales Overview
# =============================================================================

$kpis_sales = @(
    @{title='Net Sales';     m=@{entity='fact_orders';   prop='Net Sales'}}
    @{title='Order Count';   m=@{entity='fact_orders';   prop='Order Count'}}
    @{title='AOV';           m=@{entity='fact_orders';   prop='AOV'}}
    @{title='Discount %';    m=@{entity='fact_orders';   prop='Discount %'}}
    @{title='Units Sold';    m=@{entity='fact_orders';   prop='Units Sold'}}
    @{title='Customers';     m=@{entity='dim_customer';  prop='Customer Count'}}
)
$sov_visuals = @()
$sov_visuals += New-TextBoxVisual -Pos @{x=20;y=12;w=1240;h=80} -Text 'Sales Overview' -FontSize 22

# 6 KPI cards, 200x120 each, row at y=72
$x = 20
foreach ($k in $kpis_sales) {
    $sov_visuals += New-CardVisual -Pos @{x=$x;y=72;w=200;h=120} -Title $k.title -Measure $k.m
    $x += 207
}
$sov_visuals += New-BarChartVisual  -Pos @{x=20;y=200;w=400;h=235}  -Title 'Net Sales by Region'  -Category @{entity='dim_store';prop='Region'}  -Measure @{entity='fact_orders';prop='Net Sales'}
$sov_visuals += New-BarChartVisual  -Pos @{x=430;y=200;w=400;h=235} -Title 'Net Sales by Channel' -Category @{entity='fact_orders';prop='Channel'} -Measure @{entity='fact_orders';prop='Net Sales'} -VisualType 'clusteredColumnChart'
$sov_visuals += New-BarChartVisual  -Pos @{x=840;y=200;w=420;h=235} -Title 'Net Sales by Category' -Category @{entity='dim_product';prop='Category'} -Measure @{entity='fact_orders';prop='Net Sales'} -VisualType 'clusteredColumnChart'
$sov_visuals += New-LineChartVisual -Pos @{x=20;y=450;w=790;h=235}  -Title 'Net Sales over time'  -Axis @{entity='dim_date';prop='Date'} -Measure @{entity='fact_orders';prop='Net Sales'}
$sov_visuals += New-TableVisual     -Pos @{x=820;y=450;w=440;h=235} -Title 'Top Products' -Fields @(
    @{entity='dim_product'; prop='Product Name'; type='col'}
    @{entity='fact_orders'; prop='Net Sales';    type='meas'}
    @{entity='fact_orders'; prop='Order Count';  type='meas'}
)

# =============================================================================
# REPORT 2 -- Retail Sales: Operations
# =============================================================================

$kpis_ops = @(
    @{title='On-Time Ship %';    m=@{entity='fact_shipments'; prop='On-Time Ship %'}}
    @{title='Return Rate';       m=@{entity='fact_returns';   prop='Return Rate'}}
    @{title='Stockout %';        m=@{entity='fact_inventory'; prop='Stockout %'}}
    @{title='Payment Failure %'; m=@{entity='fact_payments';  prop='Payment Failure %'}}
    @{title='Avg Rating';        m=@{entity='fact_reviews';   prop='Avg Rating'}}
    @{title='5-Star %';          m=@{entity='fact_reviews';   prop='5-Star %'}}
)
$ops_visuals = @()
$ops_visuals += New-TextBoxVisual -Pos @{x=20;y=12;w=1240;h=80} -Text 'Operations Pulse' -FontSize 22
$x = 20
foreach ($k in $kpis_ops) {
    $ops_visuals += New-CardVisual -Pos @{x=$x;y=72;w=200;h=120} -Title $k.title -Measure $k.m
    $x += 207
}
$ops_visuals += New-BarChartVisual -Pos @{x=20;y=200;w=620;h=235}  -Title 'On-Time Ship % by Carrier'   -Category @{entity='fact_shipments';prop='Carrier'}   -Measure @{entity='fact_shipments';prop='On-Time Ship %'}
$ops_visuals += New-BarChartVisual -Pos @{x=650;y=200;w=610;h=235} -Title 'Return Rate by Category'    -Category @{entity='dim_product';prop='Category'} -Measure @{entity='fact_returns';prop='Return Rate'}
$ops_visuals += New-TableVisual    -Pos @{x=20;y=450;w=680;h=235} -Title 'Stores -- ops scorecard' -Fields @(
    @{entity='dim_store';     prop='Store Name';       type='col'}
    @{entity='dim_store';     prop='Region';           type='col'}
    @{entity='fact_orders';   prop='Order Count';      type='meas'}
    @{entity='fact_orders';   prop='Net Sales';        type='meas'}
    @{entity='fact_shipments';prop='On-Time Ship %';   type='meas'}
    @{entity='fact_returns';  prop='Return Rate';      type='meas'}
)
$ops_visuals += New-LineChartVisual -Pos @{x=710;y=450;w=550;h=235} -Title 'On-Time Ship % over time' -Axis @{entity='dim_date';prop='Date'} -Measure @{entity='fact_shipments';prop='On-Time Ship %'}

# =============================================================================
# REPORT 3 -- HR: Workforce Overview
# =============================================================================

$kpis_hr = @(
    @{title='Active Headcount'; m=@{entity='dim_employee'; prop='Active Headcount'}}
    @{title='Avg Tenure (yrs)'; m=@{entity='dim_employee'; prop='Avg Tenure (yrs)'}}
    @{title='Total Payroll';    m=@{entity='dim_employee'; prop='Total Payroll'}}
    @{title='Avg Salary';       m=@{entity='dim_employee'; prop='Avg Salary'}}
    @{title='Manager Count';    m=@{entity='dim_employee'; prop='Manager Count'}}
    @{title='Avg Span';         m=@{entity='dim_employee'; prop='Avg Span of Control'}}
)
$hr_visuals = @()
$hr_visuals += New-TextBoxVisual -Pos @{x=20;y=12;w=1240;h=80} -Text 'Workforce Overview' -FontSize 22
$x = 20
foreach ($k in $kpis_hr) {
    $hr_visuals += New-CardVisual -Pos @{x=$x;y=72;w=200;h=120} -Title $k.title -Measure $k.m
    $x += 207
}
$hr_visuals += New-BarChartVisual -Pos @{x=20;y=200;w=620;h=235}  -Title 'Headcount by Department' -Category @{entity='dim_employee';prop='Department'} -Measure @{entity='dim_employee';prop='Active Headcount'}
$hr_visuals += New-BarChartVisual -Pos @{x=650;y=200;w=610;h=235} -Title 'Headcount by Region'     -Category @{entity='dim_store';prop='Region'}        -Measure @{entity='dim_employee';prop='Active Headcount'}
$hr_visuals += New-TableVisual    -Pos @{x=20;y=450;w=715;h=235} -Title 'Workforce by store' -Fields @(
    @{entity='dim_store';   prop='Store Name';       type='col'}
    @{entity='dim_store';   prop='Region';           type='col'}
    @{entity='dim_employee';prop='Active Headcount'; type='meas'}
    @{entity='dim_employee';prop='Avg Tenure (yrs)'; type='meas'}
    @{entity='dim_employee';prop='Manager Count';    type='meas'}
    @{entity='dim_employee';prop='Total Payroll';    type='meas'}
)
$hr_visuals += New-BarChartVisual -Pos @{x=745;y=450;w=515;h=235} -Title 'Avg Salary by Department' -Category @{entity='dim_employee';prop='Department'} -Measure @{entity='dim_employee';prop='Avg Salary'} -VisualType 'clusteredColumnChart'

# =============================================================================
# REPORT 4 -- HR: Attrition & Tenure
# =============================================================================

$kpis_attr = @(
    @{title='Avg Tenure (yrs)'; m=@{entity='dim_employee'; prop='Avg Tenure (yrs)'}}
    @{title='< 1yr %';          m=@{entity='dim_employee'; prop='< 1yr %'}}
    @{title='> 5yr %';          m=@{entity='dim_employee'; prop='> 5yr %'}}
    @{title='Hires';            m=@{entity='dim_employee'; prop='Hires'}}
    @{title='Terminations';     m=@{entity='dim_employee'; prop='Terminations'}}
    @{title='Net Change';       m=@{entity='dim_employee'; prop='Net Change'}}
)
$attr_visuals = @()
$attr_visuals += New-TextBoxVisual -Pos @{x=20;y=12;w=1240;h=80} -Text 'Attrition & Tenure' -FontSize 22
$x = 20
foreach ($k in $kpis_attr) {
    $attr_visuals += New-CardVisual -Pos @{x=$x;y=72;w=200;h=120} -Title $k.title -Measure $k.m
    $x += 207
}
$attr_visuals += New-BarChartVisual -Pos @{x=20;y=200;w=620;h=235}  -Title 'Terminations by Department'  -Category @{entity='dim_employee';prop='Department'} -Measure @{entity='dim_employee';prop='Terminations'}
$attr_visuals += New-BarChartVisual -Pos @{x=650;y=200;w=610;h=235} -Title 'Avg Tenure (yrs) by Region' -Category @{entity='dim_store';prop='Region'}        -Measure @{entity='dim_employee';prop='Avg Tenure (yrs)'}
$attr_visuals += New-TableVisual    -Pos @{x=20;y=450;w=620;h=235} -Title 'Departments' -Fields @(
    @{entity='dim_employee'; prop='Department';                  type='col'}
    @{entity='dim_employee'; prop='Active Headcount';            type='meas'}
    @{entity='dim_employee'; prop='Avg Tenure (yrs)';            type='meas'}
    @{entity='dim_employee'; prop='Hires';                       type='meas'}
    @{entity='dim_employee'; prop='Terminations';                type='meas'}
)
$attr_visuals += New-BarChartVisual -Pos @{x=650;y=450;w=610;h=235} -Title 'Hires by Department' -Category @{entity='dim_employee';prop='Department'} -Measure @{entity='dim_employee';prop='Hires'} -VisualType 'clusteredColumnChart'

# =============================================================================
# Write all four reports
# =============================================================================

Write-Host "Writing report definitions under $OutRoot"
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null

Save-Report -Slug 'rpt_sales_overview'  -DisplayName 'Retail - Sales Overview' -Pages @(
    (New-Page -Name 'page_overview' -DisplayName 'Overview' -Ordinal 0 -Visuals $sov_visuals)
)
Save-Report -Slug 'rpt_sales_operations' -DisplayName 'Retail - Operations'    -Pages @(
    (New-Page -Name 'page_ops'      -DisplayName 'Operations' -Ordinal 0 -Visuals $ops_visuals)
)
Save-Report -Slug 'rpt_hr_workforce'     -DisplayName 'HR - Workforce Overview' -Pages @(
    (New-Page -Name 'page_workforce' -DisplayName 'Workforce' -Ordinal 0 -Visuals $hr_visuals)
)
Save-Report -Slug 'rpt_hr_attrition'     -DisplayName 'HR - Attrition & Tenure' -Pages @(
    (New-Page -Name 'page_attrition' -DisplayName 'Attrition & Tenure' -Ordinal 0 -Visuals $attr_visuals)
)

Write-Host ""
Write-Host "Done."

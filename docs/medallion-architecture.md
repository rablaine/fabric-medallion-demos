# Medallion Architecture & Source Mix

Plan for going beyond "empty DB with seed data" into a real Fabric medallion demo
that shows disparate-source ingestion, conformance, and star-schema serving.

Status: design doc. Retail vertical is the testbed; pattern then replicates to
other verticals with vertical-appropriate source flavors.

---

## Why we're doing this

Current state ships an Azure SQL DB seeded with synthetic retail data. That's
~5% of a real DSE customer scenario. Real customers have multiple disparate
source systems, varied formats, and need to land → conform → serve. The point
of the project is to demo *that* — not just "look, a database."

---

## Source mix for Retail (5 sources, 4 distinct Fabric ingest patterns)

| # | Source | Format | Fabric ingest pattern | Realistic role |
|---|---|---|---|---|
| 1 | Azure SQL (OLTP) | Relational tables | **Mirroring** | E-commerce + POS system of record |
| 2 | ADLS Gen2 supplier feeds | Parquet, dated daily files | **Shortcut** | Weekly price + inventory drops from suppliers |
| 3 | ADLS Gen2 marketing exports | JSON, dated daily files | **Shortcut** | Email/ads platform exports (campaigns, sends, clicks) |
| 4 | Event Hub clickstream | JSON events | **Eventstream → Lakehouse** | Web/app browse + cart events |
| 5 | Open-Meteo weather REST API | JSON over HTTPS | **Copy Job / Notebook (dual-implementation)** | External context — weather per store location |

The fifth source is intentionally one that can't use Mirror/Shortcut/Eventstream.
Forces the "real" ingestion patterns customers must build. Public, free,
no-auth API keeps sandbox UX clean.

### Dual implementation for source #5

We ship the weather pull two ways for the same bronze table, to show the
code-first vs low-code choice:

- **Fabric notebook** (Python `requests` → pandas → write Delta) — code-first
- **Fabric Data Pipeline** (Web source + Copy activity) OR **Dataflow Gen2** (Web connector + Power Query transforms) — low-code

Both write to the same bronze table; downstream silver/gold doesn't care which
ran. Demo can switch between them.

---

## Medallion layers

### Bronze — landing as-is

- One table per source. No transforms, no business logic.
- SQL Mirror: bronze tables are the mirror itself.
- Shortcuts: bronze tables are the shortcut.
- Eventstream: lands rows into a bronze table the eventstream targets.
- REST API: notebook/pipeline writes Delta files into bronze lakehouse.
- Schema = whatever the source gave us. Drift tolerated.

### Silver — conformed entities

Notebooks (PySpark) join, dedupe, type-coerce, mask PII, conform to canonical
entities:

- `silver.customer` = SQL.customers ⨝ marketing email-hash IDs ⨝ clickstream visitor cookies (identity resolution)
- `silver.product` = SQL.products ⨝ supplier feed enrichment (cost, lead time)
- `silver.event` = clickstream events + transactional events unified into one timeline per customer
- `silver.weather_daily` = REST API pulls aggregated to one row per (store, date)
- `silver.store` = SQL.stores ⨝ weather location lookup (lat/lon → nearest weather grid point)

### Gold — star schema

Business marts. Power BI semantic model on top.

**Facts:**
- `FactSales` (grain: order_item)
- `FactClickstream` (grain: event)
- `FactInventory` (grain: store-product-day snapshot)

**Dimensions:**
- `DimCustomer`
- `DimProduct`
- `DimStore`
- `DimSupplier`
- `DimCampaign`
- `DimDate` / `DimTime`
- `DimWeather` (or weather attributes on FactSales rows — TBD)

### Demo narratives gold enables

- "Revenue attributed to email campaign X" → marketing JSON ⨝ orders on `silver.customer.email_hash`
- "Cart-abandonment → purchase conversion" → clickstream events ⨝ orders
- "Stock-out impact on sales" → supplier inventory ⨝ orders trendline
- "Did the snowstorm tank Boston foot traffic?" → weather ⨝ store sales by date

---

## Iterative load strategy

**Problem:** our seed data is static. Real medallion demos need to show
incremental loads, watermarks, CDC. Five static sources won't tell that story.

**Solution: a "simulate activity" Fabric notebook tailed onto the end of
both pipelines** (initial-load + incremental-load), invoked as an Execute
Pipeline activity with `waitOnCompletion=false`. The pipeline reports
completion immediately; the simulation runs async in the background and
lands new data into the source systems, ready for the *next* pipeline run.

| Source | What the sim notebook does | What the next run's pipeline does |
|---|---|---|
| SQL (mirror) | Generates + `INSERT`s ~50 new orders + ~10 customer updates via JDBC | Mirror replicates within ~10s; bronze read picks up new rows |
| ADLS supplier feeds | Generates next dated Parquet and writes to live container | Pipeline reads only new files since last watermark |
| ADLS marketing JSON | Generates next dated JSON and writes to live container | Same — incremental file load |
| Event Hub clickstream | Generates + sends ~200 events via Kafka producer | Eventstream auto-lands into bronze (append-only) |
| REST API (weather) | Nothing — API serves real fresh data | Notebook/pipeline pulls `[last_pulled_date, today]` via watermark |

All simulated data is generated on the fly using shared Faker templates
(extracted from `data-gen/generate.py`). No pre-staged file pile, no
local scripts. Notebook owns generation + writing to all five sinks.

### Pipeline shape

```
Fabric Data Pipeline: initial-load (run once after deploy)
  ├─ Notebook: 10_bronze_weather_pull       ← first REST pull (all history we want)
  ├─ Notebook: 20_silver_conform            ← bronze → silver merges
  ├─ Notebook: 30_gold_marts                ← silver → star schema
  ├─ Activity: Refresh Power BI semantic model
  └─ Execute Pipeline: tick (wait=false)    ← seed first round of incremental activity

Fabric Data Pipeline: incremental-load (run on demand)
  ├─ Notebook: 10_bronze_weather_pull       ← watermark REST pull
  ├─ Notebook: 20_silver_conform            ← merges new bronze rows
  ├─ Notebook: 30_gold_marts                ← updates star schema
  ├─ Activity: Refresh Power BI semantic model
  └─ Execute Pipeline: tick (wait=false)    ← seed next round

Fabric Data Pipeline: tick (called only from above)
  └─ Notebook: 00_DEMO_simulate_activity    ← injects fake activity
```

Because `tick` is async on both pipelines, load times reflect real load
work — the simulation cost isn't on the user's clock. By the time they
run the next pipeline, the source systems already have fresh data.

### Demo loop

One button in Fabric → "Run incremental-load" → ~1-2 min later dashboards
have moved. Re-run as many times as you want; numbers keep ticking forward.

### Safety rail

The simulate-activity notebook is labeled `00_DEMO_*` and has a banner
warning at the top: "Remove from pipeline before connecting real source
systems." Prevents anyone from forking this and accidentally injecting fake
orders into production. The `tick` pipeline is similarly named and is the
only place that calls the DEMO notebook — single point to disable.

---

## Fabric capacity decision ✅

**Decided: auto-provision F2 capacity per deploy** via Bicep
(`Microsoft.Fabric/capacities`). Justification:

- All target users are Azure + Fabric tenant admins running their own capacity
- Tenant has midnight-pause automation, so idle cost is minimal
- F2 is sufficient for demo-scale loads; user can scale up post-deploy
- Capacity lives in the same RG as everything else → `az group delete` wipes it
- Eliminates "do they have a workspace? what region? what SKU?" branching

Deploy form exposes F2/F4/F8 dropdown, defaults F2.

## Workspace topology ✅

**Decided: three workspaces per vertical**, aligned to consumer audiences.
Mirrors the real customer pitch ("silver for data science, gold for the
business, bronze locked to engineering").

| Workspace | Audience | Contents | Typical RBAC |
|---|---|---|---|
| `contoso-{vertical}-1-bronze` | Data engineers | Mirror, shortcuts, eventstream, simulate notebook, ingest pipelines, weather pull notebook | Engineers only |
| `contoso-{vertical}-2-silver` | Data scientists + engineers | Conformed entities, silver notebooks, exploration notebooks, ML feature tables | Scientists (build), engineers (admin) |
| `contoso-{vertical}-3-gold` | Business / analysts / execs | Star schema lakehouse, Power BI semantic model, dashboards | Analysts (build), execs (view), engineers (admin) |

All three workspaces bind to the same F2 capacity (no extra capacity cost).
Each workspace has its own system-assigned managed identity for cross-workspace
lakehouse access and Azure resource RBAC.

Lakehouse-to-lakehouse data flow via **OneLake shortcuts**:
- silver lakehouse shortcuts to bronze tables
- gold lakehouse shortcuts to silver tables

Lakehouse uses **schemas** (GA), not folders: each lakehouse has its own
table namespace (e.g., `bronze.sql_orders`, `silver.customer`, `gold.fact_sales`).

---

## Replicating to other verticals

Same shape, vertical-appropriate source flavors:

| Vertical | OLTP (Mirror) | Files (Shortcut) | Streaming | REST API |
|---|---|---|---|---|
| Retail | Orders DB | Supplier Parquet, Marketing JSON | Clickstream events | Weather (Open-Meteo) |
| Healthcare | EMR DB | HL7/FHIR exports | Vitals telemetry (simulated) | Public health stats (CDC API) |
| Finance | Core banking DB | SWIFT message dumps | Card auth events | FX rates (exchangerate.host) |
| Manufacturing | MES DB | Quality control CSVs | OPC-UA / MQTT telemetry | Public commodity prices |
| Education | SIS DB | LMS exports | Login/activity events | IPEDS / Common Data Set |

Pattern stays identical: 5 sources, 4 ingest types, medallion lakehouse, star
schema gold, Power BI on top. Each vertical proves disparate-source
consolidation in its own industry idiom.

---

## Build order (proposed)

1. Add ADLS container layout for raw landing zones (supplier/, marketing/, weather/)
2. Add Event Hub Bicep module
3. Add Fabric Capacity Bicep module (F2 default, parameterized)
4. Extract shared Faker templates from `data-gen/generate.py` into a reusable module
5. Build the Fabric automation script (`setup-fabric.ps1`) — calls Fabric REST API to:
   - Create 3 workspaces, bind to capacity
   - Enable workspace identities, assign RBAC on SQL/EH/ADLS
   - Create lakehouses (bronze/silver/gold, one per workspace)
   - Configure Mirror, Shortcuts, Eventstream
   - Upload notebooks, create the 3 pipelines (initial-load, incremental-load, tick)
6. Build the notebooks:
   - `00_DEMO_simulate_activity` (bronze WS) — generates + writes to all sinks
   - `10_bronze_weather_pull` (bronze WS) — watermark REST pull
   - `20_silver_conform` (silver WS) — bronze shortcuts → silver tables
   - `30_gold_marts` (gold WS) — silver shortcuts → star schema
7. Build Power BI semantic model + 2-3 starter visuals on gold lakehouse SQL endpoint
8. Validate demo loop end-to-end
9. *Then* replicate pattern to next vertical (healthcare)

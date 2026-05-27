# Contoso Data Estate Project

## Vision

Build complete, realistic fictional companies with full Azure data implementations across multiple industry verticals. Enable hands-on learning, repeatable demos, and customer discovery conversations with real (synthetic) data, production-quality architectures, and executive-level reporting.

## Goals

1. **Demos that feel real** - Show customers "here's what YOUR industry looks like on Azure"
2. **Team enablement** - Colleagues can spin up, explore, learn by doing
3. **Repeatable** - Template-driven approach, spin up clean environments on demand
4. **Shareable** - Open source, team can fork and extend
5. **Comprehensive** - Full data lifecycle from source systems to executive dashboards

## Selected Verticals

### 1. Healthcare
- **Data types**: EMR/EHR, patient records, medical imaging metadata, claims, appointments
- **Key Azure products**: Purview (data classification, PII detection), Azure SQL (encrypted PHI), ADLS, Fabric
- **Compliance**: HIPAA, data lineage critical
- **Executive KPIs**: Patient outcomes, readmission rates, operational efficiency, cost per patient

### 2. Finance (Banking)
- **Data types**: Transactions, accounts, customers, fraud alerts, regulatory reports
- **Key Azure products**: Postgres/MySQL (migration story), Azure SQL (advanced security), Cosmos (real-time fraud), Fabric
- **Compliance**: Heavy auditing, encryption at rest/transit, compliance reporting
- **Executive KPIs**: Risk metrics, fraud detection rates, customer lifetime value, regulatory compliance scores

### 3. Retail
- **Data types**: E-commerce transactions, inventory, POS data, clickstream, customer profiles, product catalog
- **Key Azure products**: Fabric (real-time inventory), Cosmos (cart/session state), ADLS, Synapse, Event Hub
- **Analytics**: Recommendation engines, demand forecasting, customer segmentation
- **Executive KPIs**: Sales velocity, inventory turnover, customer acquisition cost, conversion rates

### 4. Manufacturing & Operations
- **Data types**: Factory IoT (sensors, CNC machines), fleet telemetry (GPS, diagnostics), supply chain, quality control, asset lifecycle
- **Key Azure products**: Event Hub (streaming telemetry), ADLS (data lake), Synapse/Databricks (analytics), Cosmos (time-series)
- **Scenarios**: Predictive maintenance, asset optimization (repair vs. replace), OEE tracking
- **Executive KPIs**: Overall Equipment Effectiveness (OEE), maintenance costs, asset utilization, downtime

### 5. Education (Higher Ed)
- **Data types**: Student information systems, course enrollment, grades, research data, learning management, admissions
- **Key Azure products**: Azure SQL, ADLS (research data lakes), Fabric, Purview
- **Analytics**: Student success prediction, enrollment trends, research collaboration
- **Executive KPIs**: Graduation rates, student retention, research output, enrollment trends

## Architecture Components (Per Vertical)

Each vertical should include:

### 1. Data Schema
- Entity-relationship design
- Realistic table structures
- Industry-specific relationships
- Data classification metadata

### 2. Synthetic Data Generator
- Faker-based PySpark notebooks that run inside Fabric at deploy time
- Industry-appropriate distributions and patterns
- Fixed fiscal-quarter volume per vertical (no scale options)
- Writes to BOTH Azure SQL (transactional) and ADLS Gen2 raw (CSV + Parquet daily files)
- Repo's `data-gen/` is a dev-only tool for authoring/testing the templates that the notebook reuses
- Referential integrity maintained

### 3. Azure Infrastructure (IaC)
- Bicep templates for all resources (RG, SQL, ADLS, Fabric capacity)
- Resource naming conventions via `uniqueString(resourceGroup().id)`
- RBAC and security configurations
- Cost-optimized defaults (Serverless SQL with auto-pause, F2 Fabric capacity)

### 4. Data Pipelines
- Ingestion patterns (batch, streaming, APIs)
- Transformation logic
- Data quality checks
- Orchestration (ADF or Fabric)

### 5. Governance
- Purview business glossary (industry terms)
- Data catalog
- Lineage tracking
- Sensitivity labels

### 6. Analytics & Reporting
- Fabric notebooks with common analytics patterns
- Power BI templates with industry KPIs
- Sample SQL queries for exploration
- Executive dashboard templates

### 7. Documentation
- Architecture diagrams
- Deployment guide
- Sample queries and use cases
- Learning paths for team members

## Deliverable Format

### Web Application + GitHub Repository

**User Experience:**
1. User opens web app
2. Selects vertical (Healthcare, Finance, Retail, Manufacturing & Operations, Education)
3. Configures deployment options (region, resource naming)
4. Chooses deployment method:
   - **Automated**: Authenticate to Azure tenant → app deploys everything using their credentials
   - **Manual**: Download deployment package (Bicep templates + scripts + instructions)

**Backend Architecture:**
- Web app orchestrates deployment workflow
- GitHub repository hosts all templates, scripts, and assets
- CI/CD pattern: app pulls latest templates from repo
- Deployment engine executes (all inside the user's local `deploy.ps1`):
  1. Bicep: resource group resources (SQL, ADLS, Fabric F2 capacity)
  2. Apply SQL schema
  3. Fabric REST: create 3 workspaces (bronze/silver/gold), assign capacity, create lakehouses
  4. Fabric REST: upload notebooks + create pipelines (initial-load, incremental-load, tick)
  5. Fabric REST: run the seed notebook, poll until complete (populates SQL + ADLS)
  6. Print success banner with all resource info; pause for user to read before exit
- After the script exits, the user manually triggers the initial-load pipeline in Fabric to flow data through bronze → silver → gold. Each pipeline run ends with a tick step that adds fresh activity to the sources so the next incremental load has new data.

**Repository Structure:**
```
/verticals
  /healthcare
    /schema - SQL DDL, ER diagrams
    /data-gen - Python synthetic data scripts
    /infra - Bicep templates
    /pipelines - Fabric/ADF definitions
    /governance - Purview business glossary, classifications
    /analytics - Notebooks, Power BI templates (.pbix)
    /docs - Architecture diagrams, deployment guide
    deploy.json - Orchestration manifest
  /finance
  /retail
  /manufacturing-operations
  /education
/app - Web application code
/shared - Common utilities, base templates
README.md
```

**Deployment Methods:**

**Primary: Download Deployment Package**
- User configures vertical and options in web app
- App generates customized deployment package (.zip)
- Package includes: Bicep templates, PowerShell + Bash scripts, Python data generators, README
- User downloads, extracts, and runs `deploy.ps1` or `deploy.sh`
- Script uses user's existing Azure CLI authentication (`az login`)
- No credentials sent to web app - all deployment happens locally

**Optional: Automated OAuth Deployment**
- User clicks "Sign in with Microsoft" 
- OAuth consent screen: "Allow Contoso Deployer to deploy Azure resources on your behalf"
- App receives short-lived delegated token (1 hour expiration)
- Deployment runs in background, progress shown in real-time
- Token never stored, only used for immediate deployment
- Links to deployed resources provided on completion
- **Note**: May not work in locked-down tenants - download package always available as fallback

## Success Metrics

- Each vertical can deploy in < 30 minutes
- Generates realistic data that "feels right" to industry experts
- Uses 5+ Azure data products per vertical
- Executive dashboards render with meaningful KPIs
- Team members can explore and learn independently
- Reusable in customer conversations

## Next Steps

1. Pick first vertical to build (Healthcare or Retail recommended)
2. Design detailed schema for that vertical
3. Build synthetic data generator
4. Create Bicep template for core Azure resources
5. Build one analytics notebook
6. Create one Power BI dashboard
7. Document and templatize
8. Repeat for remaining verticals

## Technical Decisions

### Web App Stack ✅
- **Backend**: FastAPI (Python)
- **Frontend**: Jinja2 templates (server-rendered HTML)
- **Orchestration**: Azure Python SDK (`azure-mgmt-resource` for Bicep deployments)
- **Data Generation**: Python Faker + custom generators
- **Background Jobs**: FastAPI BackgroundTasks for long-running deployments
- **Local Dev**: `uvicorn main:app --reload`
- **Production Hosting**: Azure App Service (when ready to share with team)

**Why**: Stay in Python ecosystem, no build tooling complexity, focus on data architecture learning (not frontend frameworks)

### Deployment Patterns ✅

**Primary: Download Deployment Package (Recommended)**
1. User selects vertical + configuration in web app
2. App generates complete deployment package (.zip):
   - Bicep templates for all Azure resources
   - PowerShell script (`deploy.ps1`) and Bash script (`deploy.sh`)
   - Python data generation scripts
   - Step-by-step README with prerequisites
   - Configuration file with user's selections
3. User downloads and extracts package
4. User runs deployment script locally using their own Azure CLI credentials
5. Script executes: resource group creation → Bicep deployment → data population → Fabric setup
6. User already authenticated via `az login` - zero credentials to our app

**Optional: Automated OAuth Deployment (Experimental)**
1. User clicks "Deploy Now" in web app
2. OAuth flow: "Sign in with Microsoft" → consent screen → delegated token
3. App deploys using user's identity and existing Azure permissions
4. Token short-lived (1 hour), never stored
5. Audit logs show: "User X deployed via Contoso Deployer app"

**OAuth Implementation Details:**
- App registration in Entra ID with delegated permission: `Azure Service Management (user_impersonation)`
- MSAL Python library for auth flow
- User authenticates at microsoft.com (never enters credentials in our app)
- May not work in locked-down tenants (conditional access, device compliance)
- Fallback: Always offer download package option

### Repository & Distribution ✅
- **Hosting**: GitHub public (for team sharing and adoption)
- **Versioning**: Semantic versioning for vertical templates
- **CI/CD**: GitHub Actions to validate Bicep templates on PR
- **App pulls templates**: Web app clones/pulls from repo at runtime (always latest version)

### Analytics Platform ✅
- **Primary**: Fabric (newer, unified experience, better for demos)
- **Alternative**: Include Synapse option for customers not on Fabric yet
- **Reasoning**: Fabric shows latest capabilities, but Synapse has broader adoption

### Medallion + Source Mix ✅
- **Detailed design**: see [docs/medallion-architecture.md](docs/medallion-architecture.md)
- **End-to-end deploy contract**: see `/memories/repo/architecture.md` (the locked-in deploy.ps1 flow)
- **Per vertical**: 5 sources (SQL OLTP, ADLS supplier Parquet, ADLS marketing CSV, Event Hub clickstream, Open-Meteo weather REST)
- **3 workspaces per vertical**: `contoso-{vertical}-1-bronze | -2-silver | -3-gold`, all bound to one auto-provisioned F2 Fabric capacity
- **Iterative tick**: every load pipeline ends with `00_DEMO_simulate_activity` (Faker) writing fresh rows to SQL + dated files to ADLS, so the next incremental run has new data
- **No local scripts**: all generation and processing happens in Fabric notebooks running in the customer tenant

### Security & Permissions ✅
- **Required Azure Permissions**: Contributor on subscription or resource group (user must have this already)
- **Secrets Management**: Auto-generated, stored in Key Vault during deployment
- *Development Phases

### Phase 1: Foundation (Current)
- [x] Define verticals and architecture components
- [x] Decide on web app stack (FastAPI + Jinja)
- [x] Define deployment patterns (download package + optional OAuth)
- [ ] Set up project structure
- [ ] Build first vertical (pick one: Healthcare or Retail)

### Phase 2: Single Vertical MVP
- [ ] Design detailed schema for first vertical
- [ ] Build synthetic data generator
- [ ] Create Bicep templates for core Azure resources
- [ ] Build deployment package generator in web app
- [ ] Test end-to-end: web app → download → deploy → verify
- [ ] Document first vertical completely

### Phase 3: Templatize & Expand
- [ ] Extract common patterns into templates
- [ ] Build remaining 4 verticals using template
- [ ] Add analytics layer (Fabric notebooks, Power BI)
- [ ] Add Purview governance layer

### Phase 4: Polish & Share
- [ ] Implement optional OAuth deployment flow
- [ ] Add deployment progress tracking
- [ ] Create cost estimation
- [ ] Deploy web app to Azure App Service
- [ ] Share with team for feedback

## Open Questions

- [ ] Include sample apps (web/mobile UI) consuming the data, or just data layer + analytics?
- [ ] Multi-region deployment scenarios? (Probably defer to v2)
- [ ] Real-time cost estimation before deployment?
- [ ] Integration with Azure Cost Management for deployed resources?
- [ ] Support for "tear down" / cleanup functionality in app?
- [ ] Allow customization of schema/data before deployment?



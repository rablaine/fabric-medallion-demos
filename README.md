# Contoso - Vertical Data Estate Builder

![Python](https://img.shields.io/badge/Python-3.11+-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-009688?logo=fastapi&logoColor=white)
![Bicep](https://img.shields.io/badge/Bicep-3178C6?logo=azurepipelines&logoColor=white)
![Medallion](https://img.shields.io/badge/Architecture-Medallion-CD7F32)
![License: MIT](https://img.shields.io/badge/License-MIT-50fa7b)

A web app that generates complete, deployable Azure data estate solutions for different industry verticals. Build full fictional companies with realistic data, production-quality architectures, and executive-level reporting - all running on Azure.

## What It Does

Pick an industry vertical (Retail, Healthcare, Finance, Manufacturing & Operations, or Education), configure your deployment, and download a complete package that deploys:

- Azure infrastructure (databases, data lakes, analytics platforms)
- Synthetic but realistic data
- Data pipelines and transformations
- Governance (Purview catalog, classifications, lineage)
- Analytics notebooks
- Power BI dashboards with executive KPIs

## Why

Theoretical demos suck. This lets Azure Data DSEs (and customers) spin up a complete reference implementation that mirrors what a real company in their industry would look like on Azure.

## Status

Early development. See [PLAN.md](PLAN.md) for the full plan and current decisions.

## Quick Start (Local Development)

```powershell
# Create virtual environment
python -m venv .venv
.venv\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt

# Run the app
uvicorn app.main:app --reload

# Open http://localhost:8000
```

## Project Structure

```
/app           - FastAPI web application
/verticals     - Per-vertical templates and assets
/shared        - Common templates and utilities
PLAN.md        - Project plan and decisions
```

## Verticals

- [x] Retail (in progress)
- [ ] Healthcare
- [ ] Finance
- [ ] Manufacturing & Operations
- [ ] Education

## License

TBD

# Contoso Tech - Synthetic Data Generator

Generates realistic consumer-electronics retail data matching the schema in `../schema/schema.sql`.

## When to use this

- You picked `medium` or `large` scale and need data (only `small` ships pre-baked in `../data/seed-small.sql`)
- You want to regenerate data with different random seeds or customize the catalog
- You want to load directly into your already-deployed Azure SQL database

## Setup

Requires Python 3.10+ and (only if using `--load`) the Microsoft ODBC Driver 18 for SQL Server.

```bash
pip install -r requirements.txt
```

ODBC Driver 18 download: https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server

## Usage

Generate a SQL file (no DB connection needed):

```bash
python generate.py --scale small    # ~5 MB,    1k customers / 10k orders
python generate.py --scale medium   # ~250 MB, 50k customers / 500k orders
python generate.py --scale large    # ~5 GB,   1M customers / 10M orders
```

Output goes to `../data/seed-<scale>.sql` by default. Override with `--output path.sql`.

Generate and load directly into your deployed Azure SQL:

```bash
python generate.py --scale medium --load \
    --server contoso3-retail-sql-xxxxxx.database.windows.net \
    --database contoso_retail
```

Auth uses your `az login` session (AAD token via `az account get-access-token`). The same account that deployed the database is already SQL admin.

## Customization

Edit `generate.py` to change:

- **Product catalog** — `PRODUCT_TEMPLATES` list
- **Brands / suppliers** — `BRANDS`, `SUPPLIERS` lists
- **Stores / warehouses** — `STORES`, `WAREHOUSES` lists
- **Customer segment / loyalty distribution** — the `random.choices(..., weights=...)` calls
- **Order status mix** — `statuses` / `status_weights` in the orders loop

Randomness is seeded (`random.seed(42)`, `Faker.seed(42)`) so re-running with the same scale produces identical output. Change the seeds at the top of the file for different data.

## Schema-data drift

If you change `../schema/schema.sql`, re-run the generator and commit a fresh `../data/seed-small.sql`. The deploy script auto-loads `seed-<scale>.sql` after the schema is applied.

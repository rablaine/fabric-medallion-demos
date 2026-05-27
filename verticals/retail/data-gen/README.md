# Contoso Tech - Synthetic Data Generator

Dev tool. Generates a fiscal quarter (~90 days) of realistic consumer-electronics retail data matching the schema in `../schema/schema.sql`.

## When to use this

End users do not need this script — the deployment zip ships with a pre-baked `../data/seed.sql` and `deploy.ps1` loads it automatically.

Run it yourself when:

- You changed `../schema/schema.sql` and need to regenerate the seed file
- You changed the product catalog / brands / stores and want fresh data
- You want to load directly into an already-deployed Azure SQL database

## Setup

Requires Python 3.10+ and (only if using `--load`) the Microsoft ODBC Driver 18 for SQL Server.

```bash
pip install -r requirements.txt
```

ODBC Driver 18 download: https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server

## Usage

Generate a SQL file (no DB connection needed):

```bash
python generate.py                  # ~25 MB, 5k customers / 1.5k products / 50k orders
python generate.py --output foo.sql # custom output path
```

Default output: `../data/seed.sql`.

Generate and load directly into your deployed Azure SQL:

```bash
python generate.py --load \
    --server contoso-retail-sql-xxxxxx.database.windows.net \
    --database contoso_retail
```

Auth uses your `az login` session (AAD token via `az account get-access-token`). The account that deployed the database is already SQL admin.

## Customization

Edit `generate.py` to change:

- **Volume** — `QUARTER` dict at the top
- **Product catalog** — `PRODUCT_TEMPLATES` list
- **Brands / suppliers** — `BRANDS`, `SUPPLIERS` lists
- **Stores / warehouses** — `STORES`, `WAREHOUSES` lists
- **Customer segment / loyalty distribution** — the `random.choices(..., weights=...)` calls
- **Order status mix** — `statuses` / `status_weights` in the orders loop

Randomness is seeded (`random.seed(42)`, `Faker.seed(42)`) so re-running produces identical output. Change the seeds at the top of the file for different data.

## Schema-data drift

If you change `../schema/schema.sql`, re-run the generator and commit a fresh `../data/seed.sql`. The deploy script auto-loads it after the schema is applied.

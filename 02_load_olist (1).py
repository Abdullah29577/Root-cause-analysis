"""
ICQA Fulfillment Defect & Lead-Time Variance Analyzer
02 - Automated ingestion: Olist CSVs -> SQL Server raw schema

Why Python instead of the SSMS Import Flat File wizard:
  - order_reviews contains embedded newlines and commas inside quoted
    Portuguese free text; the wizard mis-parses it and silently shifts columns.
  - Datetime columns arrive as 'YYYY-MM-DD HH:MM:SS' strings and get typed
    as NVARCHAR by the wizard, which breaks every DATEDIFF later.
  - This script is re-runnable and version-controlled, which is the point.

Setup:
    pip install pandas sqlalchemy pyodbc
    (needs "ODBC Driver 17 for SQL Server" or 18 installed)

Usage:
    python 02_load_olist.py --data-dir "C:/data/olist"
"""

import argparse
import sys
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text

# ----------------------------------------------------------------------
# CONNECTION - edit SERVER to match your instance
# ----------------------------------------------------------------------
SERVER = r"localhost\SQLEXPRESS"   # or "localhost", or ".\MSSQLSERVER"
DATABASE = "ICQA_Analytics"
DRIVER = "ODBC Driver 17 for SQL Server"

CONN_STR = (
    f"mssql+pyodbc://@{SERVER}/{DATABASE}"
    f"?driver={DRIVER.replace(' ', '+')}"
    "&trusted_connection=yes"
    "&TrustServerCertificate=yes"
)

# ----------------------------------------------------------------------
# FILE -> TABLE MAP, with the datetime columns that must be parsed
# ----------------------------------------------------------------------
LOAD_PLAN = [
    ("olist_customers_dataset.csv", "customers", []),
    ("olist_sellers_dataset.csv", "sellers", []),
    ("olist_products_dataset.csv", "products", []),
    ("product_category_name_translation.csv", "product_category_translation", []),
    ("olist_orders_dataset.csv", "orders", [
        "order_purchase_timestamp",
        "order_approved_at",
        "order_delivered_carrier_date",
        "order_delivered_customer_date",
        "order_estimated_delivery_date",
    ]),
    ("olist_order_items_dataset.csv", "order_items", ["shipping_limit_date"]),
    ("olist_order_payments_dataset.csv", "order_payments", []),
    ("olist_order_reviews_dataset.csv", "order_reviews", [
        "review_creation_date",
        "review_answer_timestamp",
    ]),
    ("olist_geolocation_dataset.csv", "geolocation", []),
]

# zip prefixes must stay text or leading zeros are destroyed
TEXT_COLS = {
    "customer_zip_code_prefix": str,
    "seller_zip_code_prefix": str,
    "geolocation_zip_code_prefix": str,
}


def load_table(engine, data_dir: Path, filename: str, table: str, date_cols: list) -> int:
    path = data_dir / filename
    if not path.exists():
        print(f"  !! MISSING: {path}")
        return 0

    df = pd.read_csv(
        path,
        encoding="utf-8",
        dtype={k: v for k, v in TEXT_COLS.items()},
        parse_dates=date_cols or None,
        keep_default_na=True,
    )

    # Strip stray whitespace from every text column.
    # pandas 2.x types text as 'object'; pandas 3.x types it as 'str'.
    # Select both so this works on either version.
    text_columns = [
        c for c in df.columns
        if pd.api.types.is_string_dtype(df[c]) or df[c].dtype == "object"
    ]
    for col in text_columns:
        df[col] = df[col].astype("string").str.strip()
        df[col] = df[col].replace("", pd.NA)

    # Convert pandas NA/NaT to Python None so pyodbc writes real NULLs
    df = df.astype(object).where(pd.notna(df), None)

    df.to_sql(
        table,
        engine,
        schema="raw",
        if_exists="append",
        index=False,
        chunksize=1000,
    )
    print(f"  loaded {len(df):>8,} rows -> raw.{table}")
    return len(df)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True, help="Folder holding the Olist CSVs")
    args = ap.parse_args()

    data_dir = Path(args.data_dir)
    if not data_dir.is_dir():
        sys.exit(f"Not a folder: {data_dir}")

    engine = create_engine(CONN_STR, fast_executemany=True)

    with engine.begin() as conn:
        conn.execute(text("SELECT 1"))
    print(f"Connected to {SERVER}/{DATABASE}\n")

    # truncate first so re-runs don't duplicate
    with engine.begin() as conn:
        for _, table, _ in reversed(LOAD_PLAN):
            conn.execute(text(f"IF OBJECT_ID('raw.{table}') IS NOT NULL DELETE FROM raw.{table}"))
    print("Cleared existing raw tables.\n")

    total = 0
    for filename, table, date_cols in LOAD_PLAN:
        total += load_table(engine, data_dir, filename, table, date_cols)

    print(f"\nDone. {total:,} rows loaded.")
    print("Next: run sql/03_add_keys_indexes.sql in SSMS.")


if __name__ == "__main__":
    main()

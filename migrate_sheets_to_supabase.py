#!/usr/bin/env python3
"""
Diary Note — Historical Data Migration Script
Migrates existing Google Sheets daily stock, settlements, monthly ledger,
and transfers data directly into Supabase.

Usage:
  python3 migrate_sheets_to_supabase.py \
    --supabase-url "https://YOUR_PROJECT.supabase.co" \
    --supabase-key "YOUR_SERVICE_ROLE_KEY" \
    --sheets-export-json "path_to_exported_sheets.json"

Or import individual exported CSV files into Supabase tables via SQL/Dashboard:
See MIGRATION_GUIDE.md for detailed documentation.
"""

import sys
import json
import argparse
import urllib.request

def parse_args():
    parser = argparse.ArgumentParser(description="Migrate historical dairy data to Supabase")
    parser.add_argument("--supabase-url", required=True, help="Supabase project URL")
    parser.add_argument("--supabase-key", required=True, help="Supabase service role or admin key")
    parser.add_argument("--input-json", required=False, help="Path to exported sheets JSON dump")
    return parser.parse_args()

def post_to_supabase(url, key, table, payload):
    endpoint = f"{url.rstrip('/')}/rest/v1/{table}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(endpoint, data=data, method="POST")
    req.add_header("apikey", key)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Prefer", "resolution=merge-duplicates")
    
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status in (200, 201)
    except Exception as e:
        print(f"Error posting to {table}: {e}")
        return False

def main():
    args = parse_args()
    print("Diary Note data migration helper ready.")
    if not args.input_json:
        print("No input JSON specified. Refer to MIGRATION_GUIDE.md for manual CSV / JSON import guides.")
        return

    with open(args.input_json, "r") as f:
        data = json.load(f)

    # 1. Migrate Catalog
    if "catalog" in data:
        print(f"Migrating {len(data['catalog'])} catalog products...")
        post_to_supabase(args.supabase_url, args.supabase_key, "catalog", data["catalog"])

    # 2. Migrate Daily Stock
    if "daily_stock" in data:
        print(f"Migrating {len(data['daily_stock'])} stock date records...")
        post_to_supabase(args.supabase_url, args.supabase_key, "daily_stock", data["daily_stock"])

    # 3. Migrate Settlements
    if "settlements" in data:
        print(f"Migrating {len(data['settlements'])} settlement records...")
        post_to_supabase(args.supabase_url, args.supabase_key, "settlements", data["settlements"])

    # 4. Migrate Monthly Ledger
    if "monthly_ledger" in data:
        print(f"Migrating {len(data['monthly_ledger'])} monthly ledger records...")
        post_to_supabase(args.supabase_url, args.supabase_key, "monthly_ledger", data["monthly_ledger"])

    # 5. Migrate Transfers
    if "transfers" in data:
        print(f"Migrating {len(data['transfers'])} transfer log records...")
        post_to_supabase(args.supabase_url, args.supabase_key, "transfers", data["transfers"])

    print("Data migration complete!")

if __name__ == "__main__":
    main()


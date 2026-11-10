# dairy note — Supabase Migration & Architecture Guide

This guide details the complete architecture, setup, and deployment for the unified **dairy note** application powered by Supabase.

---

## 1. Architecture Overview

- **Frontend**: A single standalone PWA application:
  - `index.html` (Unified application serving workers and owners)
- **Role-Based Experience**:
  - **Worker (Govardhini / store_1)**: Automatically restricted to Govardhini daily stock and transfers. Outlet switcher is locked to Govardhini. Settlement, monthly overview, and catalog editing tabs are hidden.
  - **Worker (Rajashyamala / store_2)**: Automatically restricted to Rajashyamala daily stock and transfers. Outlet switcher is locked to Rajashyamala. Settlement, monthly overview, and catalog editing tabs are hidden.
  - **Owner**: Full access to both stores (Govardhini & Rajashyamala), all 4 tabs (Stock Register, Transfers, Settlement, Monthly Overview), and the product catalog management modal.
- **Backend & Database**: Supabase PostgreSQL with built-in Authentication and Row Level Security (RLS).
- **Communication**: Supabase JavaScript client loaded via CDN (`@supabase/supabase-js@2`), executing standard REST queries and PostgreSQL RPCs directly.
- **Security**:
  - PostgreSQL Row Level Security enabled on all 6 tables.
  - Worker accounts are physically prevented by database policies from querying or modifying other stores, settlements, or monthly ledgers.
  - No secret / service-role keys in frontend code.
- **Authentication**: Simple Username + Password login. No email or phone numbers required from users.

---

## 2. Supabase Setup Instructions

### Step 1: Execute SQL Migration
1. Go to your [Supabase Project Dashboard](https://supabase.com/dashboard) -> **SQL Editor**.
2. Click **New query**, paste the entire contents of [`supabase_migration.sql`](./supabase_migration.sql), and click **Run**.
3. This creates all 6 tables (`profiles`, `catalog`, `daily_stock`, `settlements`, `monthly_ledger`, `transfers`), configures RLS policies, seeds the catalog products, and creates atomic transfer and stock functions with execution privileges granted strictly to authenticated callers.

### Step 2: Provision Store Users Securely
1. In the Supabase SQL Editor, open [`supabase_users_setup.sql`](./supabase_users_setup.sql).
2. Set your chosen strong passwords in the variables at the top of the `DO $$` block:
   ```sql
   v_govardhini_password   text := '<YOUR_SECURE_PASSWORD>';
   v_rajashyamala_password text := '<YOUR_SECURE_PASSWORD>';
   v_owner_password        text := '<YOUR_SECURE_PASSWORD>';
   ```
3. Click **Run**.
4. This directly creates the 3 accounts in `auth.users` with encrypted passwords (bcrypt), establishes verified identities in `auth.identities`, and registers their profile permissions in `public.profiles`.
5. **Security note**: The setup script runs within an anonymous transaction block and leaves no administrative functions exposed on the public web API.

### Step 3: Configure Frontend Credentials
In `index.html`, verify your Supabase project credentials at the top of the `<script>` block:

```javascript
const SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY";
```

> **IMPORTANT**: Use only the **Publishable / Anon key** in `index.html`. Never put the `service_role` secret key in any client-side code.

### Step 4: Login Experience
- When opening `index.html`, unauthenticated users see the clean login modal.
- Users enter their **Username** (`govardhini`, `rajashyamala`, or `owner`) and **Password**.
- Quick store selector chips are provided for convenient one-tap username selection.
- Upon successful sign-in, the application retrieves the user's authenticated profile from `public.profiles` and dynamically configures store assignment, navigation tabs, and permissions.

### Step 5: Worker Password Management Edge Function
- **Source Code**: [`supabase/functions/manage-worker-password/index.ts`](./supabase/functions/manage-worker-password/index.ts)
- **Status**: Deployed and active on Supabase Edge Runtime.
- **CLI Deployment command** (if updating in the future):
  ```bash
  supabase functions deploy manage-worker-password --no-verify-jwt
  ```
- **Security Invariants**:
  1. Validates the caller's Bearer JWT via `supabase.auth.getUser()`.
  2. Verifies the caller's profile in `public.profiles` has `role = 'owner'`.
  3. Rejects any non-owner caller with `403 Forbidden`.
  4. Restricts target accounts strictly to `govardhini` or `rajashyamala` (cannot modify other users or arbitary IDs).
  5. Validates minimum password length (8+ characters) and matching confirmation.
  6. The `SUPABASE_SERVICE_ROLE_KEY` is accessed exclusively within the server-side Deno sandbox and is never exposed to client browsers.
  7. The owner's own password is updated directly through the authenticated SDK client (`supabase.auth.updateUser`).

---

## 3. Database Schema & RLS Summary

| Table | Primary Key | Constraints / Unique | RLS Rules |
| :--- | :--- | :--- | :--- |
| `profiles` | `id (uuid)` | `username text unique` | Users can read own profile; owner can read all. Profiles cannot be modified by workers. |
| `catalog` | `id (serial)` | `name text unique` | All authenticated users can read; only owner can edit/insert/delete. |
| `daily_stock` | `id (serial)` | `unique (store_id, date)` | Workers can only read/write their assigned store. Owner has full access. |
| `settlements` | `id (serial)` | `unique (store_id, date)` | Owner only. Workers have zero read/write access. |
| `monthly_ledger` | `id (serial)` | `unique (store_id, month)` | Owner only. Workers have zero read/write access. |
| `transfers` | `id (serial)` | `check (quantity > 0)` | Visible only to participating stores and owner. |

---

## 4. Historical Data Import Formats

If you have historical data in Google Sheets, you can import it into Supabase via Dashboard (Table Editor -> Insert -> Import data via CSV) or via `migrate_sheets_to_supabase.py`.

### A. Daily Stock (`daily_stock`)
- `store_id`: `"store_1"` or `"store_2"`
- `date`: `"YYYY-MM-DD"` (e.g. `2026-11-10`)
- `entries`: JSON string representing product rows:
  ```json
  {
    "Toned Milk 500ml": {
      "old": "10", "new": "20", "tin": "0", "tout": "0",
      "closing": "5", "waste": "0", "mrp": "30", "cost": "28", "sellingPrice": "30"
    }
  }
  ```
- `total_cost`: Numeric total cost for the day (e.g. `3552.00`)
- `total_sold`: Numeric total units sold (e.g. `111`)

### B. Settlements (`settlements`)
- `store_id`: `"store_1"` or `"store_2"`
- `date`: `"YYYY-MM-DD"`
- `data`: JSON string of settlement inputs:
  ```json
  {
    "cashDenom": { "500": 4, "200": 5, "100": 10 },
    "cashSales": 5000,
    "upiSales": 3000,
    "productCost": 3552,
    "expenses": 250,
    "closingCash": 5300
  }
  ```
- `totals`: JSON summary of calculations.

### C. Monthly Ledger (`monthly_ledger`)
- `store_id`: `"store_1"` or `"store_2"`
- `month`: `"YYYY-MM"` (e.g. `2026-11`)
- `days`: JSON object mapping day numbers `"1"`..`"31"` to `{ date, cash, upi, cost, expenses, withdrawn }`.

### D. Transfers (`transfers`)
- `date`: `"YYYY-MM-DD"`
- `from_store_id`: `"store_1"` or `"store_2"`
- `to_store_id`: `"store_2"` or `"store_1"`
- `from_store_name`: `"Govardhini"` or `"Rajashyamala"`
- `to_store_name`: `"Rajashyamala"` or `"Govardhini"`
- `product_name`: Product string (e.g. `"Toned Milk 500ml"`)
- `quantity`: Positive number (e.g. `10`)

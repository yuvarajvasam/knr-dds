-- =========================================================================
-- DIARY NOTE — SUPABASE COMPLETE DATABASE MIGRATION & RLS SCHEMA
-- =========================================================================
-- This script sets up:
-- 1. Tables: profiles, catalog, daily_stock, settlements, monthly_ledger, transfers
-- 2. Row Level Security (RLS) policies enforcing store isolation and owner privileges
-- 3. Stored Functions (RPCs): save_daily_stock, record_direct_transfer,
--    cancel_direct_transfer, save_settlement, replace_catalog
-- 4. Initial seed catalog containing all 43 products with MRP, Cost, Sell Price & Category
-- =========================================================================

-- Enable required extensions
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- -------------------------------------------------------------
-- 1. USER PROFILES TABLE (Linked to auth.users)
-- -------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  role text not null check (role in ('owner', 'worker')),
  store_id text check (store_id in ('store_1', 'store_2') or store_id is null),
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;

-- -------------------------------------------------------------
-- 2. PRODUCT CATALOG TABLE
-- -------------------------------------------------------------
create table if not exists public.catalog (
  id serial primary key,
  name text unique not null,
  mrp numeric(10,2) not null default 0,
  cost numeric(10,2) not null default 0,
  sell_price numeric(10,2) not null default 0,
  category text not null default 'other',
  sort_order int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.catalog enable row level security;

-- -------------------------------------------------------------
-- 3. DAILY STOCK TABLE (Outlet & Date Specific)
-- -------------------------------------------------------------
create table if not exists public.daily_stock (
  id serial primary key,
  store_id text not null check (store_id in ('store_1', 'store_2')),
  date date not null,
  entries jsonb not null default '{}'::jsonb,
  total_cost numeric(12,2) not null default 0,
  total_sold numeric(12,2) not null default 0,
  totals jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now(),
  unique (store_id, date)
);

alter table public.daily_stock enable row level security;

-- -------------------------------------------------------------
-- 4. SETTLEMENTS TABLE (Outlet & Date Specific - Owner Only)
-- -------------------------------------------------------------
create table if not exists public.settlements (
  id serial primary key,
  store_id text not null check (store_id in ('store_1', 'store_2')),
  date date not null,
  data jsonb not null default '{}'::jsonb,
  totals jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now(),
  unique (store_id, date)
);

alter table public.settlements enable row level security;

-- -------------------------------------------------------------
-- 5. MONTHLY LEDGER TABLE (Outlet & Month Specific - Owner Only)
-- -------------------------------------------------------------
create table if not exists public.monthly_ledger (
  id serial primary key,
  store_id text not null check (store_id in ('store_1', 'store_2')),
  month text not null, -- Format: YYYY-MM
  days jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now(),
  unique (store_id, month)
);

alter table public.monthly_ledger enable row level security;

-- -------------------------------------------------------------
-- 6. TRANSFERS AUDIT & SYNC LOG TABLE
-- -------------------------------------------------------------
create table if not exists public.transfers (
  id serial primary key,
  date date not null,
  from_store_id text not null check (from_store_id in ('store_1', 'store_2')),
  to_store_id text not null check (to_store_id in ('store_1', 'store_2')),
  from_store_name text not null,
  to_store_name text not null,
  product_name text not null,
  quantity numeric(10,2) not null check (quantity > 0),
  created_at timestamptz default now(),
  created_by uuid references auth.users(id)
);

alter table public.transfers enable row level security;

-- -------------------------------------------------------------
-- SECURITY HELPER FUNCTIONS
-- -------------------------------------------------------------
create or replace function public.is_owner()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce((select role = 'owner' from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.current_user_store_id()
returns text
language sql stable security definer
set search_path = public
as $$
  select store_id from public.profiles where id = auth.uid();
$$;

-- -------------------------------------------------------------
-- ROW LEVEL SECURITY (RLS) POLICIES
-- -------------------------------------------------------------

-- PROFILES POLICIES
drop policy if exists "Users can view own profile or owner can view all" on public.profiles;
create policy "Users can view own profile or owner can view all"
  on public.profiles for select
  using (id = auth.uid() or public.is_owner());

drop policy if exists "Only owner can manage profiles" on public.profiles;
create policy "Only owner can manage profiles"
  on public.profiles for all
  using (public.is_owner());

-- CATALOG POLICIES
drop policy if exists "All authenticated users can read catalog" on public.catalog;
create policy "All authenticated users can read catalog"
  on public.catalog for select
  using (auth.role() = 'authenticated');

drop policy if exists "Only owner can insert catalog" on public.catalog;
create policy "Only owner can insert catalog"
  on public.catalog for insert
  with check (public.is_owner());

drop policy if exists "Only owner can update catalog" on public.catalog;
create policy "Only owner can update catalog"
  on public.catalog for update
  using (public.is_owner());

drop policy if exists "Only owner can delete catalog" on public.catalog;
create policy "Only owner can delete catalog"
  on public.catalog for delete
  using (public.is_owner());

-- DAILY STOCK POLICIES
drop policy if exists "Stock read policy" on public.daily_stock;
create policy "Stock read policy"
  on public.daily_stock for select
  using (public.is_owner() or store_id = public.current_user_store_id());

drop policy if exists "Stock insert policy" on public.daily_stock;
create policy "Stock insert policy"
  on public.daily_stock for insert
  with check (public.is_owner() or store_id = public.current_user_store_id());

drop policy if exists "Stock update policy" on public.daily_stock;
create policy "Stock update policy"
  on public.daily_stock for update
  using (public.is_owner() or store_id = public.current_user_store_id());

drop policy if exists "Stock delete policy" on public.daily_stock;
create policy "Stock delete policy"
  on public.daily_stock for delete
  using (public.is_owner());

-- SETTLEMENTS POLICIES (Owner only)
drop policy if exists "Settlement owner policy" on public.settlements;
create policy "Settlement owner policy"
  on public.settlements for all
  using (public.is_owner());

-- MONTHLY LEDGER POLICIES (Owner only)
drop policy if exists "Monthly ledger owner policy" on public.monthly_ledger;
create policy "Monthly ledger owner policy"
  on public.monthly_ledger for all
  using (public.is_owner());

-- TRANSFERS POLICIES
drop policy if exists "Transfers read policy" on public.transfers;
create policy "Transfers read policy"
  on public.transfers for select
  using (
    public.is_owner() or 
    from_store_id = public.current_user_store_id() or 
    to_store_id = public.current_user_store_id()
  );

drop policy if exists "Transfers insert policy" on public.transfers;
create policy "Transfers insert policy"
  on public.transfers for insert
  with check (
    public.is_owner() or 
    from_store_id = public.current_user_store_id()
  );

drop policy if exists "Transfers delete policy" on public.transfers;
create policy "Transfers delete policy"
  on public.transfers for delete
  using (
    public.is_owner() or 
    from_store_id = public.current_user_store_id() or
    to_store_id = public.current_user_store_id()
  );

-- -------------------------------------------------------------
-- STORED FUNCTIONS (RPCs) WITH NARROW VALIDATION
-- -------------------------------------------------------------

-- 1. ATOMIC SAVE DAILY STOCK & TRANSFERS SYNC
create or replace function public.save_daily_stock(
  p_date date,
  p_store_id text,
  p_entries jsonb,
  p_total_cost numeric,
  p_total_sold numeric default 0,
  p_totals jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_user_store text;
  v_other_store text;
  v_other_entries jsonb;
  v_key text;
  v_item jsonb;
  v_tout numeric;
  v_tin numeric;
  v_other_item jsonb;
  v_from_name text;
  v_to_name text;
  v_current_transfer_out numeric;
  v_current_transfer_in numeric;
  v_cat public.catalog%rowtype;
begin
  select role, store_id into v_role, v_user_store from public.profiles where id = auth.uid();
  if v_role is null then
    raise exception 'Unauthorized caller';
  end if;

  if v_role = 'worker' and v_user_store <> p_store_id then
    raise exception 'Workers are strictly restricted to their assigned store: %', v_user_store;
  end if;

  v_other_store := case when p_store_id = 'store_1' then 'store_2' else 'store_1' end;
  v_from_name := case when p_store_id = 'store_1' then 'Govardhini' else 'Rajashyamala' end;
  v_to_name := case when v_other_store = 'store_1' then 'Govardhini' else 'Rajashyamala' end;

  select entries into v_other_entries from public.daily_stock where store_id = v_other_store and date = p_date;
  if v_other_entries is null then
    v_other_entries := '{}'::jsonb;
  end if;

  for v_key, v_item in select * from jsonb_each(p_entries) loop
    v_tout := coalesce(nullif(v_item->>'tout', '')::numeric, 0);
    v_tin := coalesce(nullif(v_item->>'tin', '')::numeric, 0);

    select * into v_cat from public.catalog where name = v_key;

    v_other_item := coalesce(v_other_entries->v_key, jsonb_build_object(
      'old', '0', 'new', '0', 'tin', '0', 'tout', '0', 'closing', '0', 'waste', '0',
      'mrp', coalesce(v_cat.mrp::text, v_item->>'mrp', '0'),
      'cost', coalesce(v_cat.cost::text, v_item->>'cost', '0'),
      'sellingPrice', coalesce(v_cat.sell_price::text, v_item->>'sellingPrice', v_item->>'cost', '0')
    ));

    v_other_item := jsonb_set(v_other_item, '{tin}', to_jsonb(v_tout::text));
    v_other_item := jsonb_set(v_other_item, '{tout}', to_jsonb(v_tin::text));
    v_other_entries := jsonb_set(v_other_entries, array[v_key], v_other_item);

    -- 1. Sync outgoing transfers (tout)
    select coalesce(sum(quantity), 0) into v_current_transfer_out
    from public.transfers
    where date = p_date and from_store_id = p_store_id and to_store_id = v_other_store and product_name = v_key;

    if v_tout <> v_current_transfer_out then
      if v_tout > v_current_transfer_out then
        insert into public.transfers (date, from_store_id, to_store_id, from_store_name, to_store_name, product_name, quantity, created_by)
        values (p_date, p_store_id, v_other_store, v_from_name, v_to_name, v_key, (v_tout - v_current_transfer_out), auth.uid());
      else
        delete from public.transfers
        where date = p_date and from_store_id = p_store_id and to_store_id = v_other_store and product_name = v_key;
        if v_tout > 0 then
          insert into public.transfers (date, from_store_id, to_store_id, from_store_name, to_store_name, product_name, quantity, created_by)
          values (p_date, p_store_id, v_other_store, v_from_name, v_to_name, v_key, v_tout, auth.uid());
        end if;
      end if;
    end if;

    -- 2. Sync incoming transfers (tin)
    select coalesce(sum(quantity), 0) into v_current_transfer_in
    from public.transfers
    where date = p_date and from_store_id = v_other_store and to_store_id = p_store_id and product_name = v_key;

    if v_tin <> v_current_transfer_in then
      if v_tin > v_current_transfer_in then
        insert into public.transfers (date, from_store_id, to_store_id, from_store_name, to_store_name, product_name, quantity, created_by)
        values (p_date, v_other_store, p_store_id, v_to_name, v_from_name, v_key, (v_tin - v_current_transfer_in), auth.uid());
      else
        delete from public.transfers
        where date = p_date and from_store_id = v_other_store and to_store_id = p_store_id and product_name = v_key;
        if v_tin > 0 then
          insert into public.transfers (date, from_store_id, to_store_id, from_store_name, to_store_name, product_name, quantity, created_by)
          values (p_date, v_other_store, p_store_id, v_to_name, v_from_name, v_key, v_tin, auth.uid());
        end if;
      end if;
    end if;
  end loop;

  insert into public.daily_stock (store_id, date, entries, total_cost, total_sold, totals, updated_at)
  values (p_store_id, p_date, p_entries, p_total_cost, p_total_sold, p_totals, now())
  on conflict (store_id, date) do update set
    entries = excluded.entries,
    total_cost = excluded.total_cost,
    total_sold = excluded.total_sold,
    totals = excluded.totals,
    updated_at = now();

  insert into public.daily_stock (store_id, date, entries, total_cost, total_sold, totals, updated_at)
  values (v_other_store, p_date, v_other_entries, 0, 0, '{}'::jsonb, now())
  on conflict (store_id, date) do update set
    entries = v_other_entries,
    updated_at = now();

  return jsonb_build_object(
    'success', true, 
    'store_id', p_store_id, 
    'other_store_id', v_other_store,
    'date', p_date
  );
end;
$$;

-- 2. RECORD DIRECT TRANSFER (Atomic stock adjustment & audit logging)
create or replace function public.record_direct_transfer(
  p_date date,
  p_from_store_id text,
  p_to_store_id text,
  p_product_name text,
  p_quantity numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_user_store text;
  v_from_name text;
  v_to_name text;
  v_from_entries jsonb;
  v_to_entries jsonb;
  v_from_prod jsonb;
  v_to_prod jsonb;
  v_new_tout numeric;
  v_new_tin numeric;
  v_cat public.catalog%rowtype;
  v_transfer_id int;
begin
  select role, store_id into v_role, v_user_store from public.profiles where id = auth.uid();
  if v_role is null then
    raise exception 'Unauthorized caller';
  end if;

  if v_role = 'worker' and v_user_store <> p_from_store_id then
    raise exception 'Worker can only initiate transfers from their assigned outlet: %', v_user_store;
  end if;

  if p_from_store_id = p_to_store_id then
    raise exception 'Source and destination store cannot be identical';
  end if;

  if p_quantity <= 0 then
    raise exception 'Quantity must be positive';
  end if;

  v_from_name := case when p_from_store_id = 'store_1' then 'Govardhini' else 'Rajashyamala' end;
  v_to_name := case when p_to_store_id = 'store_1' then 'Govardhini' else 'Rajashyamala' end;

  select * into v_cat from public.catalog where name = p_product_name;

  insert into public.transfers (date, from_store_id, to_store_id, from_store_name, to_store_name, product_name, quantity, created_by)
  values (p_date, p_from_store_id, p_to_store_id, v_from_name, v_to_name, p_product_name, p_quantity, auth.uid())
  returning id into v_transfer_id;

  select coalesce(sum(quantity), 0) into v_new_tout
  from public.transfers
  where date = p_date and from_store_id = p_from_store_id and to_store_id = p_to_store_id and product_name = p_product_name;

  select entries into v_from_entries from public.daily_stock where store_id = p_from_store_id and date = p_date;
  if v_from_entries is null then v_from_entries := '{}'::jsonb; end if;
  v_from_prod := coalesce(v_from_entries->p_product_name, jsonb_build_object(
    'old', '0', 'new', '0', 'tin', '0', 'tout', '0', 'closing', '0', 'waste', '0',
    'mrp', coalesce(v_cat.mrp::text, '0'),
    'cost', coalesce(v_cat.cost::text, '0'),
    'sellingPrice', coalesce(v_cat.sell_price::text, '0')
  ));
  v_from_prod := jsonb_set(v_from_prod, '{tout}', to_jsonb(v_new_tout::text));
  v_from_entries := jsonb_set(v_from_entries, array[p_product_name], v_from_prod);

  insert into public.daily_stock (store_id, date, entries, updated_at)
  values (p_from_store_id, p_date, v_from_entries, now())
  on conflict (store_id, date) do update set
    entries = v_from_entries,
    updated_at = now();

  select coalesce(sum(quantity), 0) into v_new_tin
  from public.transfers
  where date = p_date and from_store_id = p_from_store_id and to_store_id = p_to_store_id and product_name = p_product_name;

  select entries into v_to_entries from public.daily_stock where store_id = p_to_store_id and date = p_date;
  if v_to_entries is null then v_to_entries := '{}'::jsonb; end if;
  v_to_prod := coalesce(v_to_entries->p_product_name, jsonb_build_object(
    'old', '0', 'new', '0', 'tin', '0', 'tout', '0', 'closing', '0', 'waste', '0',
    'mrp', coalesce(v_cat.mrp::text, '0'),
    'cost', coalesce(v_cat.cost::text, '0'),
    'sellingPrice', coalesce(v_cat.sell_price::text, '0')
  ));
  v_to_prod := jsonb_set(v_to_prod, '{tin}', to_jsonb(v_new_tin::text));
  v_to_entries := jsonb_set(v_to_entries, array[p_product_name], v_to_prod);

  insert into public.daily_stock (store_id, date, entries, updated_at)
  values (p_to_store_id, p_date, v_to_entries, now())
  on conflict (store_id, date) do update set
    entries = v_to_entries,
    updated_at = now();

  return jsonb_build_object(
    'success', true, 
    'transfer_id', v_transfer_id, 
    'quantity', p_quantity, 
    'product', p_product_name,
    'from_tout', v_new_tout,
    'to_tin', v_new_tin
  );
end;
$$;

-- 3. CANCEL DIRECT TRANSFER (Atomic stock rollback & audit removal)
create or replace function public.cancel_direct_transfer(
  p_date date,
  p_from_store_id text,
  p_to_store_id text,
  p_product_name text,
  p_quantity numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_user_store text;
  v_target_id int;
  v_from_entries jsonb;
  v_to_entries jsonb;
  v_from_prod jsonb;
  v_to_prod jsonb;
  v_new_tout numeric;
  v_new_tin numeric;
  v_op text := 'DELETE';
begin
  select role, store_id into v_role, v_user_store from public.profiles where id = auth.uid();
  if v_role is null then
    raise exception 'Unauthorized caller';
  end if;

  if v_role = 'worker' and v_user_store not in (p_from_store_id, p_to_store_id) then
    raise exception 'Workers can only cancel transfers involving their assigned store';
  end if;

  select id into v_target_id from public.transfers
  where date = p_date 
    and from_store_id = p_from_store_id 
    and to_store_id = p_to_store_id 
    and product_name = p_product_name 
    and quantity = p_quantity
  order by id desc
  limit 1;

  if v_target_id is null then
    return jsonb_build_object('success', false, 'message', 'Transfer record not found');
  end if;

  execute format('%s FROM public.transfers WHERE id = $1', v_op) using v_target_id;

  select coalesce(sum(quantity), 0) into v_new_tout
  from public.transfers
  where date = p_date and from_store_id = p_from_store_id and to_store_id = p_to_store_id and product_name = p_product_name;

  select entries into v_from_entries from public.daily_stock where store_id = p_from_store_id and date = p_date;
  if v_from_entries is not null and v_from_entries ? p_product_name then
    v_from_prod := v_from_entries->p_product_name;
    v_from_prod := jsonb_set(v_from_prod, '{tout}', to_jsonb(v_new_tout::text));
    v_from_entries := jsonb_set(v_from_entries, array[p_product_name], v_from_prod);
    update public.daily_stock set entries = v_from_entries, updated_at = now() where store_id = p_from_store_id and date = p_date;
  end if;

  select coalesce(sum(quantity), 0) into v_new_tin
  from public.transfers
  where date = p_date and from_store_id = p_from_store_id and to_store_id = p_to_store_id and product_name = p_product_name;

  select entries into v_to_entries from public.daily_stock where store_id = p_to_store_id and date = p_date;
  if v_to_entries is not null and v_to_entries ? p_product_name then
    v_to_prod := v_to_entries->p_product_name;
    v_to_prod := jsonb_set(v_to_prod, '{tin}', to_jsonb(v_new_tin::text));
    v_to_entries := jsonb_set(v_to_entries, array[p_product_name], v_to_prod);
    update public.daily_stock set entries = v_to_entries, updated_at = now() where store_id = p_to_store_id and date = p_date;
  end if;

  return jsonb_build_object(
    'success', true, 
    'cancelled_id', v_target_id,
    'product', p_product_name,
    'from_tout', v_new_tout,
    'to_tin', v_new_tin
  );
end;
$$;

-- 4. SAVE SETTLEMENT (With day synchronization into monthly_ledger)
create or replace function public.save_settlement(
  p_date date,
  p_store_id text,
  p_data jsonb,
  p_totals jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_month text;
  v_day_num text;
  v_monthly_days jsonb;
  v_day_data jsonb;
  v_cash text;
  v_upi text;
  v_credit text;
  v_cost text;
  v_total_sales text;
  v_gross_surplus text;
  v_expenses text;
  v_withdrawn text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role <> 'owner' then
    raise exception 'Settlement is strictly restricted to owners';
  end if;

  insert into public.settlements (store_id, date, data, totals, updated_at)
  values (p_store_id, p_date, p_data, p_totals, now())
  on conflict (store_id, date) do update set
    data = excluded.data,
    totals = excluded.totals,
    updated_at = now();

  v_cash := coalesce(p_totals->>'cash', p_data->>'cash', p_data->>'dispCalcCashSales', '0');
  v_upi := coalesce(p_totals->>'upi', p_data->>'upi', p_data->>'dispCalcUpiSales', '0');
  v_credit := coalesce(p_totals->>'credit', p_data->>'credit', p_data->>'setCreditSales', '0');
  v_total_sales := coalesce(p_totals->>'totalSales', p_data->>'totalSales', '0');
  v_cost := coalesce(p_totals->>'cost', p_data->>'cost', p_data->>'setProductCost', '0');
  v_gross_surplus := coalesce(p_totals->>'grossSurplus', p_data->>'grossSurplus', '0');
  v_expenses := coalesce(p_totals->>'expenses', p_data->>'expenses', '0');
  v_withdrawn := coalesce(p_totals->>'withdrawn', p_data->>'withdrawn', p_data->>'setWithdrawn', '0');

  v_month := to_char(p_date, 'YYYY-MM');
  v_day_num := ltrim(to_char(p_date, 'DD'), '0');

  select days into v_monthly_days from public.monthly_ledger where store_id = p_store_id and month = v_month;
  if v_monthly_days is null then
    v_monthly_days := '{}'::jsonb;
  end if;

  v_day_data := jsonb_build_object(
    'date', p_date::text,
    'cash', v_cash,
    'upi', v_upi,
    'credit', v_credit,
    'totalSales', v_total_sales,
    'cost', v_cost,
    'grossSurplus', v_gross_surplus,
    'expenses', v_expenses,
    'withdrawn', v_withdrawn
  );

  v_monthly_days := jsonb_set(v_monthly_days, array[v_day_num], v_day_data);

  insert into public.monthly_ledger (store_id, month, days, updated_at)
  values (p_store_id, v_month, v_monthly_days, now())
  on conflict (store_id, month) do update set
    days = v_monthly_days,
    updated_at = now();

  return jsonb_build_object('success', true, 'date', p_date, 'month', v_month);
end;
$$;

-- 5. REPLACE CATALOG (Owner only)
create or replace function public.replace_catalog(
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_elem jsonb;
  v_idx int := 1;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role <> 'owner' then
    raise exception 'Catalog management is strictly restricted to owners';
  end if;

  truncate table public.catalog restart identity;

  for v_elem in select * from jsonb_array_elements(p_items) loop
    insert into public.catalog (name, mrp, cost, sell_price, category, sort_order, updated_at)
    values (
      v_elem->>'name',
      coalesce((v_elem->>'mrp')::numeric, 0),
      coalesce((v_elem->>'cost')::numeric, 0),
      coalesce((v_elem->>'sell_price')::numeric, (v_elem->>'sellPrice')::numeric, (v_elem->>'sellingPrice')::numeric, (v_elem->>'cost')::numeric, 0),
      coalesce(v_elem->>'category', 'other'),
      v_idx,
      now()
    );
    v_idx := v_idx + 1;
  end loop;

  return jsonb_build_object('success', true, 'count', v_idx - 1);
end;
$$;

-- -------------------------------------------------------------
-- SEED DATA: SHARED PRODUCT CATALOG (43 PRODUCTS)
-- -------------------------------------------------------------
insert into public.catalog (name, mrp, cost, sell_price, category, sort_order)
values
  ('Toned Milk 500ml', 30, 28, 30, 'milk', 1),
  ('Pure Milk 500ml', 38, 35, 38, 'milk', 2),
  ('Gold Milk 500ml', 40, 37, 40, 'milk', 3),
  ('Special Milk 500ml', 35, 32, 35, 'milk', 4),
  ('Tea Special 480ml', 28, 25, 28, 'milk', 5),
  ('Toned Milk 200ml', 12, 10, 12, 'milk', 6),
  ('STM Milk 125ml', 8, 7, 8, 'milk', 7),
  ('6 Ltrs Pure', 425, 395, 425, 'milk', 8),
  ('DTM 10kg Bucket', 690, 640, 690, 'milk', 9),
  ('DTM 5kg Bucket', 360, 330, 360, 'curd', 10),
  ('Curd 1kg Bucket', 112, 100, 112, 'curd', 11),
  ('DTM 900gm Pouch', 63, 56, 63, 'curd', 12),
  ('Curd 500gm Pouch', 43, 38, 43, 'curd', 13),
  ('TM 450gm Pouch', 32, 28, 32, 'curd', 14),
  ('Curd 180gm Pouch', 17, 14, 17, 'curd', 15),
  ('Curd 110gm Pouch', 8, 6, 8, 'curd', 16),
  ('Curd 400gm Cup', 45, 40, 45, 'curd', 17),
  ('Curd 200gm Cup', 25, 22, 25, 'curd', 18),
  ('Sweet Lassi 200ml', 20, 17, 20, 'curd', 19),
  ('Mango Lassi 200ml', 25, 21, 25, 'curd', 20),
  ('Spiced Buttermilk 200ml', 12, 10, 12, 'curd', 21),
  ('Paneer 200gm', 85, 75, 85, 'curd', 22),
  ('Paneer 500gm', 205, 185, 205, 'curd', 23),
  ('Paneer 1kg', 400, 360, 400, 'curd', 24),
  ('Cooking Butter 500gm', 260, 235, 260, 'curd', 25),
  ('Table Butter 100gm', 58, 52, 58, 'curd', 26),
  ('Ghee 200ml Pet', 155, 140, 155, 'ghee', 27),
  ('Ghee 500ml Pouch', 360, 330, 360, 'ghee', 28),
  ('Ghee 1000ml Pouch', 710, 650, 710, 'ghee', 29),
  ('Ghee 500ml Jar', 380, 350, 380, 'ghee', 30),
  ('Ghee 1000ml Jar', 740, 680, 740, 'ghee', 31),
  ('Ghee 5000ml Tin', 3650, 3350, 3650, 'ghee', 32),
  ('Ghee 15kg Tin', 10800, 9900, 10800, 'ghee', 33),
  ('Gulab Jamun 250gm', 95, 80, 95, 'ghee', 34),
  ('Rasgulla 250gm', 95, 80, 95, 'ghee', 35),
  ('Milk Peda 200gm', 110, 95, 110, 'ghee', 36),
  ('Kaju Katli 200gm', 220, 190, 220, 'ghee', 37),
  ('Bread 400gm', 38, 32, 38, 'bakery', 38),
  ('Milk Bread 400gm', 42, 36, 42, 'bakery', 39),
  ('Brown Bread 400gm', 48, 42, 48, 'bakery', 40),
  ('Pav Bun 200gm', 25, 20, 25, 'bakery', 41),
  ('Rusk 200gm', 40, 34, 40, 'bakery', 42),
  ('Tea Rusk 300gm', 55, 48, 55, 'bakery', 43)
on conflict (name) do update set
  mrp = excluded.mrp,
  cost = excluded.cost,
  sell_price = excluded.sell_price,
  category = excluded.category,
  sort_order = excluded.sort_order;

-- -------------------------------------------------------------
-- SECURITY HARDENING & PERMISSIONS
-- -------------------------------------------------------------
-- Remove any legacy public user creation RPC
drop function if exists public.setup_store_user(text, text, text, text);
drop function if exists public.setup_store_user(text, text, text);
drop function if exists public.setup_store_user;

-- Revoke public and anon execution on mutation functions; grant strictly to authenticated
revoke execute on function public.save_daily_stock from public, anon;
grant execute on function public.save_daily_stock to authenticated;

revoke execute on function public.record_direct_transfer from public, anon;
grant execute on function public.record_direct_transfer to authenticated;

revoke execute on function public.cancel_direct_transfer from public, anon;
grant execute on function public.cancel_direct_transfer to authenticated;

revoke execute on function public.save_settlement from public, anon;
grant execute on function public.save_settlement to authenticated;

revoke execute on function public.replace_catalog from public, anon;
grant execute on function public.replace_catalog to authenticated;



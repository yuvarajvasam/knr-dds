-- =========================================================================
-- DIARY NOTE — INCREMENTAL MIGRATION: TRANSFERS & SETTLEMENT ATOMIC SYNC
-- =========================================================================
-- This script updates:
-- 1. save_daily_stock: Two-way atomic sync of tin/tout and public.transfers
-- 2. record_direct_transfer: Atomic transfer creation and stock sync
-- 3. cancel_direct_transfer: Atomic transfer cancellation and stock sync
-- 4. save_settlement: Accurate settlement totals and monthly_ledger sync
-- =========================================================================

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

-- 2. ATOMIC RECORD DIRECT TRANSFER
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

-- 3. ATOMIC CANCEL DIRECT TRANSFER
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

-- 4. ATOMIC SAVE SETTLEMENT & MONTHLY LEDGER SYNC
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

  return jsonb_build_object('success', true, 'store_id', p_store_id, 'date', p_date);
end;
$$;


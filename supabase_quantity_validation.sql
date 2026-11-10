-- =========================================================================
-- DIARY NOTE — INCREMENTAL MIGRATION: RELIABLE QUANTITY VALIDATION
-- =========================================================================
-- This script updates:
-- 1. save_daily_stock: Rejects negative values, transfers out > inbound stock,
--    and closing+waste > remaining stock (impossible negative sales).
-- 2. record_direct_transfer: Enforces positive quantity, different stores,
--    and verifies source store has sufficient available uncommitted stock.
-- 3. cancel_direct_transfer: Verifies destination store hasn't already
--    committed/transferred out the received stock before cancelling.
-- =========================================================================

-- 1. SAVE DAILY STOCK (Strict Quantity Validation & Atomic Sync)
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
  v_old numeric;
  v_new numeric;
  v_tin numeric;
  v_tout numeric;
  v_closing numeric;
  v_waste numeric;
  v_inbound numeric;
  v_avail numeric;
  v_sold numeric;
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

  -- Phase 1: STRICT VALIDATION across all products in batch
  for v_key, v_item in select * from jsonb_each(p_entries) loop
    v_old := coalesce(nullif(v_item->>'old', '')::numeric, 0);
    v_new := coalesce(nullif(v_item->>'new', '')::numeric, 0);
    v_tin := coalesce(nullif(v_item->>'tin', '')::numeric, 0);
    v_tout := coalesce(nullif(v_item->>'tout', '')::numeric, 0);
    v_closing := coalesce(nullif(v_item->>'closing', '')::numeric, 0);
    v_waste := coalesce(nullif(v_item->>'waste', '')::numeric, 0);

    -- Rule A: Non-negative finite numbers
    if v_old < 0 or v_new < 0 or v_tin < 0 or v_tout < 0 or v_closing < 0 or v_waste < 0 then
      raise exception 'Validation error for "%": quantities must be non-negative numbers', v_key;
    end if;

    -- Rule B: Transfer Out cannot exceed available inbound stock
    v_inbound := v_old + v_new + v_tin;
    if v_tout > v_inbound then
      raise exception 'Validation error for "%": Transfer Out (%) exceeds available stock (%)', v_key, v_tout, v_inbound;
    end if;

    -- Rule C: Closing + Waste cannot exceed remaining available stock
    v_avail := v_inbound - v_tout;
    v_sold := v_avail - (v_closing + v_waste);
    if v_sold < 0 then
      raise exception 'Validation error for "%": Closing (%) and Waste (%) exceed remaining available stock (%)', v_key, v_closing, v_waste, v_avail;
    end if;
  end loop;

  -- Phase 2: ATOMIC RECONCILIATION & SYNC
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


-- 2. RECORD DIRECT TRANSFER (Strict Source Availability Check & Atomic Sync)
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
  v_old numeric;
  v_new numeric;
  v_tin numeric;
  v_cls numeric;
  v_wst numeric;
  v_gross_inbound numeric;
  v_current_tout numeric;
  v_committed numeric;
  v_avail_to_transfer numeric;
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

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Transfer quantity must be a positive number';
  end if;

  v_from_name := case when p_from_store_id = 'store_1' then 'Govardhini' else 'Rajashyamala' end;
  v_to_name := case when p_to_store_id = 'store_1' then 'Govardhini' else 'Rajashyamala' end;

  select * into v_cat from public.catalog where name = p_product_name;

  -- Verify source store availability
  select entries into v_from_entries from public.daily_stock where store_id = p_from_store_id and date = p_date;
  if v_from_entries is not null and v_from_entries ? p_product_name then
    v_from_prod := v_from_entries->p_product_name;
    v_old := coalesce(nullif(v_from_prod->>'old', '')::numeric, 0);
    v_new := coalesce(nullif(v_from_prod->>'new', '')::numeric, 0);
    v_tin := coalesce(nullif(v_from_prod->>'tin', '')::numeric, 0);
    v_cls := coalesce(nullif(v_from_prod->>'closing', '')::numeric, 0);
    v_wst := coalesce(nullif(v_from_prod->>'waste', '')::numeric, 0);
  else
    v_old := 0; v_new := 0; v_tin := 0; v_cls := 0; v_wst := 0;
  end if;

  v_gross_inbound := v_old + v_new + v_tin;

  select coalesce(sum(quantity), 0) into v_current_tout
  from public.transfers
  where date = p_date and from_store_id = p_from_store_id and to_store_id = p_to_store_id and product_name = p_product_name;

  v_committed := v_cls + v_wst;
  v_avail_to_transfer := v_gross_inbound - (v_current_tout + v_committed);
  if v_avail_to_transfer < 0 then
    v_avail_to_transfer := 0;
  end if;

  if p_quantity > v_avail_to_transfer then
    raise exception 'Insufficient stock in % for "%": requested % units, but only % available (inbound: %, existing transfers: %, closing/waste: %)',
      v_from_name, p_product_name, p_quantity, v_avail_to_transfer, v_gross_inbound, v_current_tout, v_committed;
  end if;

  insert into public.transfers (date, from_store_id, to_store_id, from_store_name, to_store_name, product_name, quantity, created_by)
  values (p_date, p_from_store_id, p_to_store_id, v_from_name, v_to_name, p_product_name, p_quantity, auth.uid())
  returning id into v_transfer_id;

  select coalesce(sum(quantity), 0) into v_new_tout
  from public.transfers
  where date = p_date and from_store_id = p_from_store_id and to_store_id = p_to_store_id and product_name = p_product_name;

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


-- 3. CANCEL DIRECT TRANSFER (Destination Commitment Check & Atomic Rollback)
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
  v_to_old numeric;
  v_to_new numeric;
  v_to_tin numeric;
  v_to_tout numeric;
  v_to_cls numeric;
  v_to_wst numeric;
  v_new_dest_inbound numeric;
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

  -- Validate destination store has not committed this stock
  select entries into v_to_entries from public.daily_stock where store_id = p_to_store_id and date = p_date;
  if v_to_entries is not null and v_to_entries ? p_product_name then
    v_to_prod := v_to_entries->p_product_name;
    v_to_old := coalesce(nullif(v_to_prod->>'old', '')::numeric, 0);
    v_to_new := coalesce(nullif(v_to_prod->>'new', '')::numeric, 0);
    v_to_tin := coalesce(nullif(v_to_prod->>'tin', '')::numeric, 0);
    v_to_tout := coalesce(nullif(v_to_prod->>'tout', '')::numeric, 0);
    v_to_cls := coalesce(nullif(v_to_prod->>'closing', '')::numeric, 0);
    v_to_wst := coalesce(nullif(v_to_prod->>'waste', '')::numeric, 0);

    v_new_dest_inbound := v_to_old + v_to_new + (v_to_tin - p_quantity);
    if v_new_dest_inbound < 0 or v_new_dest_inbound < v_to_tout then
      raise exception 'Cannot cancel transfer of % units: Destination store has already transferred out this stock (new inbound: %, transfer out: %)',
        p_quantity, v_new_dest_inbound, v_to_tout;
    end if;

    if (v_new_dest_inbound - v_to_tout) < (v_to_cls + v_to_wst) then
      raise exception 'Cannot cancel transfer of % units: Destination store has already committed this stock (closing: %, waste: %, remaining: %)',
        p_quantity, v_to_cls, v_to_wst, (v_new_dest_inbound - v_to_tout);
    end if;
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


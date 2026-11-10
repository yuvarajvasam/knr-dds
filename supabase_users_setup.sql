-- =========================================================================
-- DIARY NOTE — SECURE ADMIN USER PROVISIONING
-- =========================================================================
-- Instructions:
-- 1. Open your Supabase Dashboard -> SQL Editor (run as postgres superuser).
-- 2. Set your strong, secret passwords in the variables below (replace <ENTER_...>):
--    - v_govardhini_password
--    - v_rajashyamala_password
--    - v_owner_password
-- 3. Click Run.
--
-- SECURITY NOTES:
-- - This script runs inside an anonymous DO $$ ... $$ transaction block.
-- - It NEVER exposes an unrestricted function to the public Supabase API.
-- - Passwords are cryptographically hashed using PostgreSQL pgcrypto bcrypt.
-- - No plaintext passwords are stored in the database.
-- =========================================================================

-- Ensure pgcrypto extension is active for bcrypt password hashing
create extension if not exists pgcrypto with schema extensions;

-- Ensure any legacy public user creation RPC is removed from the public API
drop function if exists public.setup_store_user(text, text, text, text);
drop function if exists public.setup_store_user(text, text, text);
drop function if exists public.setup_store_user;

do $$
declare
  -- -----------------------------------------------------------------------
  -- CONFIGURE PASSWORDS (ADMIN ONLY - DO NOT COMMIT REAL PASSWORDS TO GIT)
  -- Replace the placeholders below before running in the Supabase SQL editor:
  -- -----------------------------------------------------------------------
  v_govardhini_password   text := 'gova2242';
  v_rajashyamala_password text := 'raja2020';
  v_owner_password        text := '9640301657';

  -- Account loop variables
  r record;
  v_user_id uuid;
  v_encrypted_pw text;
  v_email text;
begin
  -- Safety check: ensure placeholder passwords have been replaced
  if v_govardhini_password like '<ENTER_%' or
     v_rajashyamala_password like '<ENTER_%' or
     v_owner_password like '<ENTER_%' then
    raise exception 'Safety check failed: Please replace the placeholder passwords (<ENTER_...>) with your chosen passwords before running this script.';
  end if;

  if length(v_govardhini_password) < 8 or
     length(v_rajashyamala_password) < 8 or
     length(v_owner_password) < 8 then
    raise exception 'Safety check failed: Passwords must be at least 8 characters long.';
  end if;

  for r in (
    select
      'govardhini' as username,
      'worker' as role,
      'store_1' as store_id,
      v_govardhini_password as raw_password
    union all
    select
      'rajashyamala' as username,
      'worker' as role,
      'store_2' as store_id,
      v_rajashyamala_password as raw_password
    union all
    select
      'owner' as username,
      'owner' as role,
      null as store_id,
      v_owner_password as raw_password
  ) loop
    v_email := lower(trim(r.username)) || '@diarynote.internal';
    v_encrypted_pw := extensions.crypt(r.raw_password, extensions.gen_salt('bf'));

    -- Check if user already exists in auth.users
    select id into v_user_id from auth.users where email = v_email;

    if v_user_id is null then
      v_user_id := gen_random_uuid();

      -- Insert into auth.users (initializing token fields to empty strings to avoid GoTrue scan errors)
      insert into auth.users (
        id,
        instance_id,
        role,
        aud,
        email,
        encrypted_password,
        email_confirmed_at,
        confirmation_token,
        recovery_token,
        email_change_token_new,
        email_change,
        phone_change,
        phone_change_token,
        email_change_token_current,
        reauthentication_token,
        raw_app_meta_data,
        raw_user_meta_data,
        created_at,
        updated_at
      ) values (
        v_user_id,
        '00000000-0000-0000-0000-000000000000'::uuid,
        'authenticated',
        'authenticated',
        v_email,
        v_encrypted_pw,
        now(),
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('username', r.username, 'store_id', r.store_id, 'role', r.role),
        now(),
        now()
      );
    else
      -- Update existing user password, confirmation, and clear any legacy null tokens
      update auth.users
      set encrypted_password = v_encrypted_pw,
          email_confirmed_at = coalesce(email_confirmed_at, now()),
          confirmation_token = coalesce(confirmation_token, ''),
          recovery_token = coalesce(recovery_token, ''),
          email_change_token_new = coalesce(email_change_token_new, ''),
          email_change = coalesce(email_change, ''),
          phone_change = coalesce(phone_change, ''),
          phone_change_token = coalesce(phone_change_token, ''),
          email_change_token_current = coalesce(email_change_token_current, ''),
          reauthentication_token = coalesce(reauthentication_token, ''),
          raw_app_meta_data = '{"provider":"email","providers":["email"]}'::jsonb,
          raw_user_meta_data = jsonb_build_object('username', r.username, 'store_id', r.store_id, 'role', r.role),
          updated_at = now()
      where id = v_user_id;
    end if;

    -- Refresh identity in auth.identities
    delete from auth.identities where user_id = v_user_id;

    insert into auth.identities (
      id,
      provider_id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    ) values (
      gen_random_uuid(),
      v_user_id::text,
      v_user_id,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email',
      now(),
      now(),
      now()
    );

    -- Upsert profile in public.profiles (users cannot modify this table due to RLS)
    insert into public.profiles (id, username, role, store_id)
    values (v_user_id, r.username, r.role, r.store_id)
    on conflict (id) do update set
      username = r.username,
      role = r.role,
      store_id = r.store_id;

  end loop;

  raise notice 'All store accounts successfully provisioned.';
end;
$$;

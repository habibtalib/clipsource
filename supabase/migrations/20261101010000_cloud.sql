-- ClipSource Cloud: plans, profiles, registered devices, device-gated clip writes, plan-based retention.
-- Still end-to-end encrypted: the server additionally sees an opaque device_id per row and the device list
-- (name + kind), which is account metadata shown on the account page.

-- Plans

create table if not exists public.plan_limits (
    plan text primary key,
    device_limit int,  -- null = unlimited; counts Macs only, the web viewer is free
    retention_days int not null
);

insert into public.plan_limits (plan, device_limit, retention_days) values
    ('free', 2, 7),
    ('pro', null, 365)
on conflict (plan) do update set device_limit = excluded.device_limit, retention_days = excluded.retention_days;

alter table public.plan_limits enable row level security;
drop policy if exists plan_limits_select on public.plan_limits;
create policy plan_limits_select on public.plan_limits for select to authenticated using (true);
revoke all on public.plan_limits from anon, authenticated;
grant select on public.plan_limits to authenticated;

-- Profiles: one per user, written only by the trigger, the RPCs (security definer) and the Stripe webhook (service role).

create table if not exists public.profiles (
    user_id uuid primary key references auth.users (id) on delete cascade,
    plan text not null default 'free' references public.plan_limits (plan),
    stripe_customer_id text unique,
    subscription_status text,
    current_period_end timestamptz,
    -- `created` of the newest Stripe event applied; older events arriving late are skipped.
    stripe_event_at timestamptz,
    updated_at timestamptz default now()
);

alter table public.profiles enable row level security;
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant all on public.profiles to service_role;

create or replace function public.profiles_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
    for each row execute function public.profiles_touch();

create or replace function public.handle_new_user() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id) values (new.id) on conflict (user_id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
    for each row execute function public.handle_new_user();

alter table public.profiles add column if not exists stripe_event_at timestamptz;

insert into public.profiles (user_id) select id from auth.users on conflict (user_id) do nothing;

-- Devices

create table if not exists public.devices (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    device_id text not null,
    name text not null,
    kind text not null check (kind in ('mac', 'web')),
    created_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    primary key (user_id, device_id)
);

alter table public.devices enable row level security;
drop policy if exists devices_select on public.devices;
create policy devices_select on public.devices for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.devices from anon, authenticated;
grant select on public.devices to authenticated;
grant all on public.devices to service_role;

-- Clips: every write must come from a device registered to the same user.

alter table public.clips add column if not exists device_id text;

drop policy if exists clips_insert on public.clips;
drop policy if exists clips_update on public.clips;
create policy clips_insert on public.clips for insert to authenticated with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.devices d where d.user_id = (select auth.uid()) and d.device_id = clips.device_id)
);
create policy clips_update on public.clips for update to authenticated
    using (user_id = (select auth.uid()))
    with check (
        user_id = (select auth.uid())
        and exists (select 1 from public.devices d where d.user_id = (select auth.uid()) and d.device_id = clips.device_id)
    );

-- RPCs. Security definer so they can write devices/profiles; each acts only on auth.uid().

create or replace function public.register_device(p_device_id text, p_name text, p_kind text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    uid uuid := auth.uid();
    v_plan text;
    v_limit int;
    v_retention int;
    v_used int;
    v_name text := left(btrim(coalesce(p_name, '')), 100);
begin
    if uid is null then
        return jsonb_build_object('ok', false, 'error', 'not_authenticated');
    end if;
    if p_kind is null or p_kind not in ('mac', 'web') then
        return jsonb_build_object('ok', false, 'error', 'invalid_kind');
    end if;
    if p_device_id is null or length(p_device_id) not between 1 and 128 then
        return jsonb_build_object('ok', false, 'error', 'invalid_device_id');
    end if;
    if v_name = '' then
        v_name := case p_kind when 'web' then 'Web' else 'Mac' end;
    end if;

    insert into profiles (user_id) values (uid) on conflict (user_id) do nothing;
    -- Lock the profile row so two devices registering at once cannot both slip under the limit.
    select p.plan, l.device_limit, l.retention_days into v_plan, v_limit, v_retention
    from profiles p join plan_limits l on l.plan = p.plan
    where p.user_id = uid
    for update of p;

    if exists (select 1 from devices where user_id = uid and device_id = p_device_id) then
        -- Kind is fixed at first registration, so a web device can never turn into an uncounted Mac.
        update devices set name = v_name, last_seen_at = now() where user_id = uid and device_id = p_device_id;
    else
        select count(*) into v_used from devices where user_id = uid and kind = 'mac';
        if p_kind = 'mac' and v_limit is not null and v_used >= v_limit then
            return jsonb_build_object('ok', false, 'error', 'device_limit', 'plan', v_plan,
                                      'device_limit', v_limit, 'devices_used', v_used);
        end if;
        insert into devices (user_id, device_id, name, kind) values (uid, p_device_id, v_name, p_kind);
    end if;

    select count(*) into v_used from devices where user_id = uid and kind = 'mac';
    return jsonb_build_object('ok', true, 'plan', v_plan, 'device_limit', v_limit,
                              'devices_used', v_used, 'retention_days', v_retention);
end;
$$;

create or replace function public.account_status() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    uid uuid := auth.uid();
    result jsonb;
begin
    if uid is null then
        return jsonb_build_object('ok', false, 'error', 'not_authenticated');
    end if;
    insert into profiles (user_id) values (uid) on conflict (user_id) do nothing;
    select jsonb_build_object(
        'plan', p.plan,
        'subscription_status', p.subscription_status,
        'current_period_end', p.current_period_end,
        'device_limit', l.device_limit,
        'retention_days', l.retention_days,
        'devices_used', (select count(*) from devices d where d.user_id = uid and d.kind = 'mac'),
        'devices', coalesce((
            select jsonb_agg(jsonb_build_object('device_id', d.device_id, 'name', d.name, 'kind', d.kind,
                                                'last_seen_at', d.last_seen_at) order by d.created_at)
            from devices d where d.user_id = uid
        ), '[]'::jsonb)
    ) into result
    from profiles p join plan_limits l on l.plan = p.plan
    where p.user_id = uid;
    return result;
end;
$$;

create or replace function public.remove_device(p_device_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        return jsonb_build_object('ok', false, 'error', 'not_authenticated');
    end if;
    delete from devices where user_id = auth.uid() and device_id = p_device_id;
    return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.rename_device(p_device_id text, p_name text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_name text := left(btrim(coalesce(p_name, '')), 100);
begin
    if auth.uid() is null then
        return jsonb_build_object('ok', false, 'error', 'not_authenticated');
    end if;
    if v_name = '' then
        return jsonb_build_object('ok', false, 'error', 'invalid_name');
    end if;
    update devices set name = v_name where user_id = auth.uid() and device_id = p_device_id;
    if not found then
        return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    return jsonb_build_object('ok', true);
end;
$$;

-- Retention: drop rows older than the owner's plan allows. created_at is client-supplied, so the server-set
-- updated_at caps it (a row stamped in the future still expires retention_days after its last write).

create or replace function public.prune_expired_clips() returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    removed int;
begin
    delete from clips c
    where least(c.created_at, c.updated_at) < now() - make_interval(days => coalesce(
        (select l.retention_days from profiles p join plan_limits l on l.plan = p.plan where p.user_id = c.user_id),
        (select retention_days from plan_limits where plan = 'free')));
    get diagnostics removed = row_count;
    return removed;
end;
$$;

-- Supabase grants EXECUTE on new public functions to anon/authenticated by default; narrow that explicitly.
revoke all on function public.register_device(text, text, text), public.account_status(),
    public.remove_device(text), public.rename_device(text, text) from public, anon;
grant execute on function public.register_device(text, text, text), public.account_status(),
    public.remove_device(text), public.rename_device(text, text) to authenticated;
revoke all on function public.prune_expired_clips(), public.handle_new_user(), public.profiles_touch()
    from public, anon, authenticated;

-- Hourly retention job. cron.schedule with a name replaces an existing job of that name, so re-runs are safe.

create extension if not exists pg_cron;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'clipsource-prune-expired-clips') then
        perform cron.unschedule('clipsource-prune-expired-clips');
    end if;
    perform cron.schedule('clipsource-prune-expired-clips', '17 * * * *', 'select public.prune_expired_clips()');
end;
$$;

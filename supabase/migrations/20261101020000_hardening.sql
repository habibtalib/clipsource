-- ClipSource Cloud hardening (security review, 2026-11-01). Re-runnable.
-- Devices are bound to the auth session that registered them. Clip reads and writes need a device bound to
-- the caller's session. Removing a device revokes that session. Quotas, tombstone and iteration guards.

-- Limits

alter table public.plan_limits add column if not exists web_device_limit int not null default 3;
alter table public.plan_limits add column if not exists max_rows int;
update public.plan_limits set max_rows = 5000 where plan = 'free';
update public.plan_limits set max_rows = 50000 where plan = 'pro';
update public.plan_limits set web_device_limit = 3;

-- Session binding

alter table public.devices add column if not exists session_id uuid;

/** The caller's auth session (JWT claim `session_id`), or null. */
create or replace function public.jwt_session_id() returns uuid
language sql
stable
set search_path = ''
as $$
    select nullif(auth.jwt() ->> 'session_id', '')::uuid
$$;

/** True if `p_device_id` is a device of the caller bound to the caller's session. */
create or replace function public.is_session_device(p_device_id text) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.devices d
        where d.user_id = auth.uid() and d.device_id = p_device_id and d.session_id = public.jwt_session_id()
    )
$$;

/** True if the caller's session has any registered device (a removed device has none). */
create or replace function public.has_session_device() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.devices d where d.user_id = auth.uid() and d.session_id = public.jwt_session_id()
    )
$$;

-- Clips: every read and write needs a device bound to this session. On update, the new row must also
-- satisfy this, so a PATCH that leaves device_id alone is checked against that old id and this session.

drop policy if exists clips_select on public.clips;
drop policy if exists clips_insert on public.clips;
drop policy if exists clips_update on public.clips;
drop policy if exists clips_delete on public.clips;
create policy clips_select on public.clips for select to authenticated
    using (user_id = (select auth.uid()) and (select public.has_session_device()));
create policy clips_insert on public.clips for insert to authenticated
    with check (user_id = (select auth.uid()) and public.is_session_device(device_id));
create policy clips_update on public.clips for update to authenticated
    using (user_id = (select auth.uid()) and (select public.has_session_device()))
    with check (user_id = (select auth.uid()) and public.is_session_device(device_id));
create policy clips_delete on public.clips for delete to authenticated
    using (user_id = (select auth.uid()) and (select public.has_session_device()));

-- sync_keys: read/create stay open to the owner, because unlock can run before device registration.
-- Replace and delete need a registered device.
drop policy if exists sync_keys_update on public.sync_keys;
drop policy if exists sync_keys_delete on public.sync_keys;
create policy sync_keys_update on public.sync_keys for update to authenticated
    using (user_id = (select auth.uid()) and (select public.has_session_device()))
    with check (user_id = (select auth.uid()));
create policy sync_keys_delete on public.sync_keys for delete to authenticated
    using (user_id = (select auth.uid()) and (select public.has_session_device()));

-- Quotas and sanity checks. NOT VALID: enforced for new rows without failing on legacy rows.

alter table public.clips drop constraint if exists clips_payload_size;
alter table public.clips add constraint clips_payload_size check (length(payload) <= 1572864) not valid;
alter table public.clips drop constraint if exists clips_hash_format;
alter table public.clips add constraint clips_hash_format check (hash ~ '^[0-9a-f]{64}$') not valid;
alter table public.clips drop constraint if exists clips_device_id_length;
alter table public.clips add constraint clips_device_id_length check (length(device_id) <= 128) not valid;
alter table public.sync_keys drop constraint if exists sync_keys_iterations_range;
alter table public.sync_keys add constraint sync_keys_iterations_range
    check (iterations between 100000 and 10000000) not valid;

-- Per-user row cap. A counter on profiles, kept by statement-level triggers, avoids counting rows per insert.
-- AFTER INSERT sees only rows really inserted, not upserts that turned into updates.

alter table public.profiles add column if not exists clip_count int not null default 0;
update public.profiles p set clip_count = (select count(*) from public.clips c where c.user_id = p.user_id);

create or replace function public.clips_count_insert() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_over record;
begin
    with added as (select user_id, count(*) as n from new_rows group by user_id),
    bumped as (
        update profiles p set clip_count = p.clip_count + a.n from added a
        where p.user_id = a.user_id
        returning p.user_id, p.plan, p.clip_count
    )
    select b.user_id, b.clip_count, l.max_rows into v_over
    from bumped b join plan_limits l on l.plan = b.plan
    where l.max_rows is not null and b.clip_count > l.max_rows
    limit 1;
    if found then
        raise exception 'row_limit' using errcode = 'P0001',
            detail = format('Synced history is limited to %s entries on this plan.', v_over.max_rows),
            hint = 'Remove old entries or upgrade.';
    end if;
    return null;
end;
$$;

create or replace function public.clips_count_delete() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    update profiles p set clip_count = greatest(0, p.clip_count - d.n)
    from (select user_id, count(*) as n from old_rows group by user_id) d
    where p.user_id = d.user_id;
    return null;
end;
$$;

drop trigger if exists clips_count_insert on public.clips;
create trigger clips_count_insert after insert on public.clips
    referencing new table as new_rows for each statement execute function public.clips_count_insert();
drop trigger if exists clips_count_delete on public.clips;
create trigger clips_count_delete after delete on public.clips
    referencing old table as old_rows for each statement execute function public.clips_count_delete();

-- Tombstones win over stale pushes. A device that missed a delete can push the old entry again (created_at
-- not newer). The row is then silently kept as a tombstone, so the push still succeeds. Only device_id takes
-- the incoming value, so the RLS WITH CHECK (applied after BEFORE triggers) passes. Runs after
-- clips_set_updated_at (trigger names fire in alphabetical order) and keeps the old updated_at.

create or replace function public.clips_tombstone_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
    incoming_device text := new.device_id;
begin
    if old.deleted and not new.deleted and new.created_at <= old.created_at then
        new := old;
        new.device_id := incoming_device;
    end if;
    return new;
end;
$$;

drop trigger if exists clips_tombstone_guard on public.clips;
create trigger clips_tombstone_guard before update on public.clips
    for each row execute function public.clips_tombstone_guard();

-- RPCs

create or replace function public.register_device(p_device_id text, p_name text, p_kind text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    uid uuid := auth.uid();
    v_session uuid := public.jwt_session_id();
    v_plan text;
    v_limit int;
    v_web_limit int;
    v_retention int;
    v_used int;
    v_existing devices%rowtype;
    v_name text := left(btrim(coalesce(p_name, '')), 100);
begin
    if uid is null or v_session is null then
        return jsonb_build_object('ok', false, 'error', 'not_authenticated');
    end if;
    -- A removed device's access token stays valid until expiry, but its session row is gone.
    if not exists (select 1 from auth.sessions s where s.id = v_session and s.user_id = uid) then
        return jsonb_build_object('ok', false, 'error', 'session_revoked');
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
    -- Lock the profile row so concurrent registrations cannot both slip under a limit.
    select p.plan, l.device_limit, l.web_device_limit, l.retention_days
    into v_plan, v_limit, v_web_limit, v_retention
    from profiles p join plan_limits l on l.plan = p.plan
    where p.user_id = uid
    for update of p;

    select * into v_existing from devices where user_id = uid and device_id = p_device_id;
    if found then
        -- Another live sign-in owns this ID. Only a device whose session ended (signed out, revoked) is taken over.
        if v_existing.session_id is distinct from v_session
           and exists (select 1 from auth.sessions s where s.id = v_existing.session_id) then
            return jsonb_build_object('ok', false, 'error', 'device_in_use');
        end if;
        -- Kind is fixed at first registration.
        update devices set name = v_name, last_seen_at = now(), session_id = v_session
        where user_id = uid and device_id = p_device_id;
    else
        if p_kind = 'mac' then
            select count(*) into v_used from devices where user_id = uid and kind = 'mac';
            if v_limit is not null and v_used >= v_limit then
                return jsonb_build_object('ok', false, 'error', 'device_limit', 'plan', v_plan,
                                          'device_limit', v_limit, 'devices_used', v_used);
            end if;
        else
            select count(*) into v_used from devices where user_id = uid and kind = 'web';
            if v_web_limit is not null and v_used >= v_web_limit then
                return jsonb_build_object('ok', false, 'error', 'web_limit', 'plan', v_plan,
                                          'web_device_limit', v_web_limit, 'web_devices_used', v_used);
            end if;
        end if;
        insert into devices (user_id, device_id, name, kind, session_id)
        values (uid, p_device_id, v_name, p_kind, v_session);
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
    v_session uuid := public.jwt_session_id();
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
        'web_device_limit', l.web_device_limit,
        'retention_days', l.retention_days,
        'max_rows', l.max_rows,
        'rows_used', p.clip_count,
        'devices_used', (select count(*) from devices d where d.user_id = uid and d.kind = 'mac'),
        'devices', coalesce((
            select jsonb_agg(jsonb_build_object('device_id', d.device_id, 'name', d.name, 'kind', d.kind,
                                                'last_seen_at', d.last_seen_at,
                                                'current', d.session_id is not distinct from v_session)
                             order by d.created_at)
            from devices d where d.user_id = uid
        ), '[]'::jsonb)
    ) into result
    from profiles p join plan_limits l on l.plan = p.plan
    where p.user_id = uid;
    return result;
end;
$$;

-- Removing a device also deletes its auth session, which revokes its refresh token (refresh_tokens cascade).
-- Its access token stays valid until expiry, but with no device bound to that session it can no longer read or
-- write clips.
create or replace function public.remove_device(p_device_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_session uuid;
begin
    if auth.uid() is null then
        return jsonb_build_object('ok', false, 'error', 'not_authenticated');
    end if;
    delete from devices where user_id = auth.uid() and device_id = p_device_id returning session_id into v_session;
    if v_session is not null
       and not exists (select 1 from devices where user_id = auth.uid() and session_id = v_session) then
        delete from auth.sessions where id = v_session and user_id = auth.uid();
    end if;
    return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.register_device(text, text, text), public.account_status(),
    public.remove_device(text), public.rename_device(text, text) from public, anon;
grant execute on function public.register_device(text, text, text), public.account_status(),
    public.remove_device(text), public.rename_device(text, text) to authenticated;
-- Used inside RLS policies, so authenticated must be able to execute them. They only reveal facts about the caller.
revoke all on function public.jwt_session_id(), public.is_session_device(text), public.has_session_device()
    from public, anon;
grant execute on function public.jwt_session_id(), public.is_session_device(text), public.has_session_device()
    to authenticated;
revoke all on function public.clips_count_insert(), public.clips_count_delete(), public.clips_tombstone_guard()
    from public, anon, authenticated;

-- Realtime: DELETE events are not filtered by RLS or by the subscription's event filter. Every subscriber,
-- including other users and removed sessions, receives the deleted row's id and commit time. Clients only need
-- INSERT/UPDATE: a delete synced between devices is a tombstone UPDATE, and hard deletes (retention,
-- "delete my data") need no notification. So deletes and truncates are not published at all. Re-apply this if
-- the publication is ever recreated, e.g. from the dashboard.
alter publication supabase_realtime set (publish = 'insert, update');

-- Keyset paging: the engine pulls by (updated_at, id). This index covers the old (user_id, updated_at) one.
create index if not exists clips_user_updated_id_idx on public.clips (user_id, updated_at, id);
drop index if exists public.clips_user_updated_idx;

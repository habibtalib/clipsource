-- ClipSource v0.3 sync. The server stores only ciphertext (payload) and HMAC hashes; it never sees clip text.

create table if not exists public.clips (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    hash text not null,
    payload text,
    created_at timestamptz not null,
    updated_at timestamptz not null default now(),
    deleted boolean not null default false,
    unique (user_id, hash)
);

create index if not exists clips_user_updated_idx on public.clips (user_id, updated_at);

create table if not exists public.sync_keys (
    user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
    salt text not null,
    check_value text not null,
    iterations int not null default 600000,
    created_at timestamptz default now()
);

-- Server clock wins: clients pull with updated_at >= cursor, so it must never come from a client.
create or replace function public.clips_set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

drop trigger if exists clips_set_updated_at on public.clips;
create trigger clips_set_updated_at
    before insert or update on public.clips
    for each row execute function public.clips_set_updated_at();

alter table public.clips enable row level security;
alter table public.sync_keys enable row level security;

drop policy if exists clips_select on public.clips;
drop policy if exists clips_insert on public.clips;
drop policy if exists clips_update on public.clips;
drop policy if exists clips_delete on public.clips;
create policy clips_select on public.clips for select to authenticated using (user_id = (select auth.uid()));
create policy clips_insert on public.clips for insert to authenticated with check (user_id = (select auth.uid()));
create policy clips_update on public.clips for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy clips_delete on public.clips for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists sync_keys_select on public.sync_keys;
drop policy if exists sync_keys_insert on public.sync_keys;
drop policy if exists sync_keys_update on public.sync_keys;
drop policy if exists sync_keys_delete on public.sync_keys;
create policy sync_keys_select on public.sync_keys for select to authenticated using (user_id = (select auth.uid()));
create policy sync_keys_insert on public.sync_keys for insert to authenticated with check (user_id = (select auth.uid()));
create policy sync_keys_update on public.sync_keys for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy sync_keys_delete on public.sync_keys for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.clips, public.sync_keys from anon;
grant select, insert, update, delete on public.clips, public.sync_keys to authenticated;

-- Realtime postgres_changes respects RLS, so each user only hears about their own rows.
do $$
begin
    if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'clips'
    ) then
        alter publication supabase_realtime add table public.clips;
    end if;
end;
$$;

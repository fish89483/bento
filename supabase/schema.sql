-- Bento MVP shared state. This single JSONB row mirrors the current client model.
-- This policy is intentionally public for trusted testing: anyone with the app URL
-- and project publishable key can read or write the shared state.
create table if not exists public.bento_state (
  id text primary key check (id = 'shared'),
  state jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.bento_state enable row level security;
grant select, insert, update on public.bento_state to anon, authenticated;

drop policy if exists "Bento test readers" on public.bento_state;
create policy "Bento test readers"
  on public.bento_state for select
  to anon, authenticated
  using (id = 'shared');

drop policy if exists "Bento test writers insert" on public.bento_state;
create policy "Bento test writers insert"
  on public.bento_state for insert
  to anon, authenticated
  with check (id = 'shared');

drop policy if exists "Bento test writers update" on public.bento_state;
create policy "Bento test writers update"
  on public.bento_state for update
  to anon, authenticated
  using (id = 'shared')
  with check (id = 'shared');

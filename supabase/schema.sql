-- Bento relational schema.
-- bento_state is retained as a compatibility layer for the current client,
-- which still reads and writes the complete shared state as one JSONB row.

create extension if not exists pgcrypto;

create table if not exists public.bento_state (
  id text primary key check (id = 'shared'),
  state jsonb not null,
  updated_at timestamptz not null default now()
);

-- Merge concurrent whole-state client writes instead of letting a stale browser
-- replace records added by another browser. Distinct record IDs are append-only;
-- existing records win when the same ID is present in both snapshots.
create or replace function public.jsonb_array_union(a jsonb, b jsonb)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(value order by first_order, value::text), '[]'::jsonb)
  from (
    select value, min(ord) as first_order
    from (
      select value, 0 as ord from jsonb_array_elements(coalesce(a, '[]'::jsonb))
      union all
      select value, 1 as ord from jsonb_array_elements(coalesce(b, '[]'::jsonb))
    ) values_with_order
    group by value
  ) unique_values
$$;

create or replace function public.jsonb_array_union_by_id(a jsonb, b jsonb)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(value order by ord, record_id), '[]'::jsonb)
  from (
    select distinct on (record_id) value, record_id, ord
    from (
      select value, value->>'id' as record_id, 0 as ord
      from jsonb_array_elements(coalesce(a, '[]'::jsonb))
      union all
      select value, value->>'id' as record_id, 1 as ord
      from jsonb_array_elements(coalesce(b, '[]'::jsonb))
    ) values_with_order
    where record_id is not null
    order by record_id, ord
  ) unique_records
$$;

create or replace function public.merge_bento_state(current_state jsonb, incoming_state jsonb)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  with old_state as (
    select coalesce(current_state, '{}'::jsonb) as doc,
           coalesce(current_state->'data', '{}'::jsonb) as data
  ), new_state as (
    select coalesce(incoming_state, '{}'::jsonb) as doc,
           coalesce(incoming_state->'data', '{}'::jsonb) as data
  ), old_items as (
    select value->>'id' as id, value as item
    from old_state, jsonb_array_elements(coalesce(data->'items', '[]'::jsonb))
  ), new_items as (
    select value->>'id' as id, value as item
    from new_state, jsonb_array_elements(coalesce(data->'items', '[]'::jsonb))
  ), item_pairs as (
    select old_items.id, old_items.item as old_item, new_items.item as new_item, 0 as ord
    from old_items left join new_items using (id)
    union all
    select new_items.id, null::jsonb, new_items.item, 1 as ord
    from new_items left join old_items using (id) where old_items.id is null
  ), merged_items as (
    select id, min(ord) as first_order,
      (coalesce(old_item, '{}'::jsonb) || coalesce(new_item, '{}'::jsonb)) ||
      jsonb_build_object(
        'tags', public.jsonb_array_union(old_item->'tags', new_item->'tags'),
        'meals', public.jsonb_array_union_by_id(old_item->'meals', new_item->'meals')
      ) as item
    from item_pairs group by id, old_item, new_item
  ), merged_data as (
    select (old_state.data || new_state.data) || jsonb_build_object(
      'people', public.jsonb_array_union(old_state.data->'people', new_state.data->'people'),
      'items', coalesce((select jsonb_agg(item order by first_order, id) from merged_items), '[]'::jsonb)
    ) as data
    from old_state cross join new_state
  )
  select (old_state.doc || new_state.doc) || jsonb_build_object(
    'data', merged_data.data,
    'accounts', public.jsonb_array_union_by_id(old_state.doc->'accounts', new_state.doc->'accounts')
  )
  from old_state cross join new_state cross join merged_data
$$;

create or replace function public.merge_bento_state_before_update()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  new.state := public.merge_bento_state(old.state, new.state);
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists bento_state_merge_concurrent_writes on public.bento_state;
create trigger bento_state_merge_concurrent_writes
before update on public.bento_state
for each row execute function public.merge_bento_state_before_update();

-- Keep the normalized tables synchronized while the current app still writes
-- bento_state. This makes the relational tables a live mirror, not a one-time seed.
create or replace function public.sync_bento_state_to_relational()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare state_doc jsonb := new.state;
begin
  insert into public.people(name)
  select distinct trim(value)
  from jsonb_array_elements_text(coalesce(state_doc #> '{data,people}', '[]'::jsonb))
  where trim(value) <> '' on conflict (name) do nothing;

  insert into public.shops(name)
  select distinct trim(item->>'shop')
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  where trim(coalesce(item->>'shop','')) <> '' on conflict (name) do nothing;

  insert into public.items(id, shop_id, name, current_price)
  select item->>'id', shop.id, trim(item->>'name'), nullif(item->>'price','')::numeric
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  join public.shops shop on shop.name = trim(item->>'shop')
  where coalesce(item->>'id','') <> '' and trim(coalesce(item->>'name','')) <> ''
  on conflict (id) do update set shop_id = excluded.shop_id, name = excluded.name,
    current_price = excluded.current_price, updated_at = now();

  insert into public.people(name)
  select distinct trim(meal->>'person')
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals', '[]'::jsonb)) meal
  where trim(coalesce(meal->>'person','')) <> '' on conflict (name) do nothing;

  insert into public.meals(id, item_id, person_id, meal_date, price, rating, note, created_by)
  select meal->>'id', item->>'id', person.id,
    coalesce(nullif(meal->>'date','')::date, current_date),
    coalesce(nullif(meal->>'price','')::numeric, nullif(item->>'price','')::numeric),
    nullif(meal->>'rating','')::smallint, coalesce(meal->>'note',''), meal->'createdBy'
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals', '[]'::jsonb)) meal
  join public.people person on person.name = trim(meal->>'person')
  where coalesce(meal->>'id','') <> '' and coalesce(item->>'id','') <> ''
  on conflict (id) do update set item_id = excluded.item_id, person_id = excluded.person_id,
    meal_date = excluded.meal_date, price = excluded.price, rating = excluded.rating,
    note = excluded.note, created_by = excluded.created_by, updated_at = now();

  insert into public.tags(name)
  select distinct trim(tag.value)
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements_text(coalesce(item->'tags','[]'::jsonb)) tag(value)
  where trim(tag.value) <> '' on conflict (name) do nothing;

  insert into public.tags(name)
  select distinct trim(tag.value)
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals','[]'::jsonb)) meal
  cross join lateral jsonb_array_elements_text(coalesce(meal->'tags','[]'::jsonb)) tag(value)
  where trim(tag.value) <> '' on conflict (name) do nothing;

  insert into public.item_tags(item_id, tag_id)
  select item->>'id', tag.id
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements_text(coalesce(item->'tags','[]'::jsonb)) value(name)
  join public.tags tag on tag.name = trim(value.name)
  on conflict do nothing;

  insert into public.meal_tags(meal_id, tag_id)
  select meal->>'id', tag.id
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals','[]'::jsonb)) meal
  cross join lateral jsonb_array_elements_text(coalesce(meal->'tags','[]'::jsonb)) value(name)
  join public.tags tag on tag.name = trim(value.name)
  on conflict do nothing;

  insert into public.display_accounts(id, email, nickname)
  select account->>'id', lower(trim(account->>'email')), trim(account->>'nickname')
  from jsonb_array_elements(coalesce(state_doc->'accounts','[]'::jsonb)) account
  where coalesce(account->>'id','') <> '' and coalesce(account->>'email','') <> ''
    and coalesce(account->>'nickname','') <> ''
  on conflict (id) do update set email = excluded.email, nickname = excluded.nickname;

  return new;
end;
$$;

drop trigger if exists bento_state_sync_relational on public.bento_state;
create trigger bento_state_sync_relational
after insert or update on public.bento_state
for each row execute function public.sync_bento_state_to_relational();

create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- People are meal participants, not login accounts.
create table if not exists public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.items (
  id text primary key,
  shop_id uuid not null references public.shops(id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  current_price numeric(10, 2) check (current_price is null or current_price >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, name)
);

alter table public.items add column if not exists current_price numeric(10, 2)
  check (current_price is null or current_price >= 0);

create table if not exists public.meals (
  id text primary key,
  item_id text not null references public.items(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete restrict,
  meal_date date not null,
  price numeric(10, 2) check (price is null or price >= 0),
  rating smallint check (rating between 1 and 5),
  note text not null default '',
  created_by jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tags (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.item_tags (
  item_id text not null references public.items(id) on delete cascade,
  tag_id uuid not null references public.tags(id) on delete cascade,
  primary key (item_id, tag_id)
);

create table if not exists public.meal_tags (
  meal_id text not null references public.meals(id) on delete cascade,
  tag_id uuid not null references public.tags(id) on delete cascade,
  primary key (meal_id, tag_id)
);

-- Current client-created display accounts. These are not verified auth users.
create table if not exists public.display_accounts (
  id text primary key,
  email text not null unique,
  nickname text not null,
  created_at timestamptz not null default now()
);

create index if not exists items_shop_id_idx on public.items(shop_id);
create index if not exists meals_item_date_idx on public.meals(item_id, meal_date desc);
create index if not exists meals_person_date_idx on public.meals(person_id, meal_date desc);
create index if not exists item_tags_tag_id_idx on public.item_tags(tag_id);
create index if not exists meal_tags_tag_id_idx on public.meal_tags(tag_id);

-- Public policies match the existing trusted-test setup. Replace these before
-- using real or private data; the frontend currently relies on anonymous access.
alter table public.bento_state enable row level security;
alter table public.shops enable row level security;
alter table public.people enable row level security;
alter table public.items enable row level security;
alter table public.meals enable row level security;
alter table public.tags enable row level security;
alter table public.item_tags enable row level security;
alter table public.meal_tags enable row level security;
alter table public.display_accounts enable row level security;

grant select, insert, update, delete on public.shops, public.people, public.items,
  public.meals, public.tags, public.item_tags, public.meal_tags,
  public.display_accounts to anon, authenticated;
grant select, insert, update on public.bento_state to anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['bento_state','shops','people','items','meals','tags','item_tags','meal_tags','display_accounts'] loop
    execute format('drop policy if exists "Bento trusted test access" on public.%I', t);
    execute format('create policy "Bento trusted test access" on public.%I for all to anon, authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- One-time, repeatable import of the existing JSONB row into relational tables.
-- Run after the app has seeded bento_state or after migrate:supabase.
do $$
declare state_doc jsonb;
begin
  select state into state_doc from public.bento_state where id = 'shared';
  if state_doc is null then
    raise notice 'No bento_state row found; relational import skipped.';
    return;
  end if;

  insert into public.people(name)
  select distinct trim(value) from jsonb_array_elements_text(coalesce(state_doc #> '{data,people}', '[]'::jsonb))
  where trim(value) <> '' on conflict (name) do nothing;

  insert into public.shops(name)
  select distinct trim(item->>'shop') from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  where trim(coalesce(item->>'shop','')) <> '' on conflict (name) do nothing;

  insert into public.items(id, shop_id, name, current_price)
  select item->>'id', shop.id, trim(item->>'name'), nullif(item->>'price','')::numeric
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  join public.shops shop on shop.name = trim(item->>'shop')
  where coalesce(item->>'id','') <> '' and trim(coalesce(item->>'name','')) <> ''
  on conflict (id) do update set shop_id = excluded.shop_id, name = excluded.name,
    current_price = excluded.current_price, updated_at = now();

  insert into public.people(name)
  select distinct trim(meal->>'person')
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals', '[]'::jsonb)) meal
  where trim(coalesce(meal->>'person','')) <> '' on conflict (name) do nothing;

  insert into public.meals(id, item_id, person_id, meal_date, price, rating, note, created_by)
  select meal->>'id', item->>'id', person.id,
    coalesce(nullif(meal->>'date','')::date, current_date),
    coalesce(nullif(meal->>'price','')::numeric, nullif(item->>'price','')::numeric),
    nullif(meal->>'rating','')::smallint,
    coalesce(meal->>'note',''), meal->'createdBy'
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals', '[]'::jsonb)) meal
  join public.people person on person.name = trim(meal->>'person')
  where coalesce(meal->>'id','') <> '' and coalesce(item->>'id','') <> ''
  on conflict (id) do update set item_id = excluded.item_id, person_id = excluded.person_id,
    meal_date = excluded.meal_date, price = excluded.price, rating = excluded.rating,
    note = excluded.note, created_by = excluded.created_by, updated_at = now();

  insert into public.tags(name)
  select distinct trim(tag.value)
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements_text(coalesce(item->'tags','[]'::jsonb)) tag(value)
  where trim(tag.value) <> '' on conflict (name) do nothing;

  insert into public.tags(name)
  select distinct trim(tag.value)
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals','[]'::jsonb)) meal
  cross join lateral jsonb_array_elements_text(coalesce(meal->'tags','[]'::jsonb)) tag(value)
  where trim(tag.value) <> '' on conflict (name) do nothing;

  insert into public.item_tags(item_id, tag_id)
  select item->>'id', tag.id
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements_text(coalesce(item->'tags','[]'::jsonb)) value(name)
  join public.tags tag on tag.name = trim(value.name)
  on conflict do nothing;

  insert into public.meal_tags(meal_id, tag_id)
  select meal->>'id', tag.id
  from jsonb_array_elements(coalesce(state_doc #> '{data,items}', '[]'::jsonb)) item
  cross join lateral jsonb_array_elements(coalesce(item->'meals','[]'::jsonb)) meal
  cross join lateral jsonb_array_elements_text(coalesce(meal->'tags','[]'::jsonb)) value(name)
  join public.tags tag on tag.name = trim(value.name)
  on conflict do nothing;

  insert into public.display_accounts(id, email, nickname)
  select account->>'id', lower(trim(account->>'email')), trim(account->>'nickname')
  from jsonb_array_elements(coalesce(state_doc->'accounts','[]'::jsonb)) account
  where coalesce(account->>'id','') <> '' and coalesce(account->>'email','') <> ''
    and coalesce(account->>'nickname','') <> ''
  on conflict (id) do update set email = excluded.email, nickname = excluded.nickname;
end $$;

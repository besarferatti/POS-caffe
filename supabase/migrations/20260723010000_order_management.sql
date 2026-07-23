-- Phase 3: operational POS catalog and order workflow.
create type public.table_status as enum ('available', 'occupied', 'reserved');
create type public.order_status as enum ('open', 'closed', 'cancelled');

create table public.dining_tables (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  status public.table_status not null default 'available',
  position_x numeric(8, 2) not null default 0,
  position_y numeric(8, 2) not null default 0,
  created_at timestamptz not null default now(),
  unique (name)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 100),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete restrict,
  name text not null check (char_length(trim(name)) between 1 and 160),
  price numeric(12, 2) not null check (price >= 0),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.dining_tables(id) on delete restrict,
  status public.order_status not null default 'open',
  created_by uuid not null references public.profiles(id) on delete restrict,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  subtotal numeric(12, 2) not null default 0 check (subtotal >= 0),
  total numeric(12, 2) not null default 0 check (total >= 0),
  constraint orders_closed_at_matches_status check ((status = 'closed') = (closed_at is not null))
);
create unique index orders_one_open_order_per_table on public.orders(table_id) where status = 'open';

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  price numeric(12, 2) not null check (price >= 0),
  notes text not null default '',
  sent_to_kitchen boolean not null default false,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint order_items_deleted_by_matches check ((deleted_at is null) = (deleted_by is null))
);

create index order_items_active_order_idx on public.order_items(order_id) where deleted_at is null;
create index products_category_idx on public.products(category_id) where active;

create or replace function public.refresh_order_totals()
returns trigger language plpgsql security definer set search_path = public as $$
declare affected_order_id uuid;
begin
  affected_order_id := coalesce(new.order_id, old.order_id);
  update public.orders
  set subtotal = coalesce((select sum(quantity * price) from public.order_items where order_id = affected_order_id and deleted_at is null), 0),
      total = coalesce((select sum(quantity * price) from public.order_items where order_id = affected_order_id and deleted_at is null), 0)
  where id = affected_order_id;
  return null;
end;
$$;
create trigger order_items_refresh_totals after insert or update or delete on public.order_items for each row execute procedure public.refresh_order_totals();

create or replace function public.sync_table_order_state()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.status = 'open' and new.status <> 'open') then
    update public.dining_tables set status = 'available' where id = old.table_id and status = 'occupied';
  end if;
  if tg_op <> 'DELETE' and new.status = 'open' then
    update public.dining_tables set status = 'occupied' where id = new.table_id;
  end if;
  return null;
end;
$$;
create trigger orders_sync_table_state after insert or update or delete on public.orders for each row execute procedure public.sync_table_order_state();

-- A transaction-safe entry point prevents duplicate active orders when two staff members tap a table together.
create or replace function public.open_order_for_table(target_table_id uuid)
returns public.orders language plpgsql security definer set search_path = public as $$
declare result public.orders;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  -- Serialize opens per table; the partial unique index remains a final safety net.
  perform 1 from public.dining_tables where id = target_table_id for update;
  if not found then raise exception 'Table not found'; end if;
  select * into result from public.orders where table_id = target_table_id and status = 'open' for update;
  if found then return result; end if;
  insert into public.orders (table_id, created_by) values (target_table_id, auth.uid()) returning * into result;
  return result;
end;
$$;

alter table public.dining_tables enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create policy "staff use dining tables" on public.dining_tables for all to authenticated using (true) with check (true);
create policy "staff read catalog categories" on public.categories for select to authenticated using (true);
create policy "staff read catalog products" on public.products for select to authenticated using (true);
create policy "staff use orders" on public.orders for all to authenticated using (true) with check (true);
create policy "staff use order items" on public.order_items for all to authenticated using (true) with check (true);

grant execute on function public.open_order_for_table(uuid) to authenticated;

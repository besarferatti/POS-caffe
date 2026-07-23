-- Phase 1: application identities, roles, permissions, and row-level security.
create type public.app_role as enum ('admin', 'manager', 'worker');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 120),
  role public.app_role not null default 'worker',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.permissions (
  key text primary key check (key ~ '^[a-z]+:[a-z]+$'),
  description text not null
);

create table public.role_permissions (
  role public.app_role not null,
  permission_key text not null references public.permissions(key) on delete cascade,
  primary key (role, permission_key)
);

alter table public.profiles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;

create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_app_role() = 'admin'
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1)));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at before update on public.profiles
  for each row execute procedure public.set_updated_at();

-- A user can view their own profile; managers can read all staff; only admins manage roles.
create policy "users read own profile or manager reads staff" on public.profiles for select to authenticated
  using (id = auth.uid() or public.current_app_role() in ('admin', 'manager'));
create policy "admins update profiles" on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "authenticated users read permissions" on public.permissions for select to authenticated using (true);
create policy "authenticated users read role permissions" on public.role_permissions for select to authenticated using (true);

revoke all on function public.current_app_role() from public;
revoke all on function public.is_admin() from public;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.is_admin() to authenticated;
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

-- The editor stores the full canvas document here.  Existing installations may already have this table.
create table if not exists public.floor_layouts (
  id integer primary key default 1 check (id = 1),
  layout jsonb not null default '{"objects": []}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.floor_layouts enable row level security;
create policy "staff use floor layouts" on public.floor_layouts for all to authenticated using (true) with check (true);
-- Use the floor-plan editor's immutable table object UUID as the POS table key.
-- This migration intentionally leaves dining_tables intact for backwards compatibility,
-- but new orders no longer depend on rows in that legacy normalized table.

alter table public.orders drop constraint orders_table_id_fkey;

drop trigger orders_sync_table_state on public.orders;
drop function public.sync_table_order_state();

-- A transaction-safe entry point prevents duplicate active orders when two staff
-- members select the same saved floor object at once. The layout row is locked
-- while its canvas JSON is checked, so no label/name is used as an identifier.
create or replace function public.open_order_for_table(target_table_id uuid)
returns public.orders language plpgsql security definer set search_path = public as $$
declare result public.orders;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  perform 1 from public.floor_layouts where id = 1
    and jsonb_path_exists(
      layout,
      '$.** ? ((@.id == $table_id || @.uuid == $table_id || @.objectId == $table_id) && (@.type like_regex ".*table.*" flag "i" || @.objectType like_regex ".*table.*" flag "i" || @.kind like_regex ".*table.*" flag "i" || @.tableType like_regex ".*table.*" flag "i" || @.tableShape like_regex "^(round|square|rectangle|rectangular)$" flag "i" || @.shape like_regex "^(round|square|rectangle|rectangular)(-table)?$" flag "i"))',
      jsonb_build_object('table_id', to_jsonb(target_table_id::text))
    )
    for update;
  if not found then raise exception 'Floor table not found'; end if;

  select * into result from public.orders where table_id = target_table_id and status = 'open' for update;
  if found then return result; end if;

  insert into public.orders (table_id, created_by) values (target_table_id, auth.uid()) returning * into result;
  return result;
end;
$$;

grant execute on function public.open_order_for_table(uuid) to authenticated;
-- This migration must complete before any constraint, index, function, or DML
-- references the new enum labels.  Supabase applies each migration separately.
alter type public.order_status add value if not exists 'sent';
alter type public.order_status add value if not exists 'partially_paid';
alter type public.order_status add value if not exists 'paid';
alter type public.order_status add value if not exists 'voided';
alter type public.order_status add value if not exists 'internal_only';

-- Required boundary: PostgreSQL cannot safely use a newly-added enum label until
-- the transaction that added it has committed. This is already guaranteed when
-- applying the chronological migration files separately.
commit;

-- Production hardening for the single-site POS.  Existing rows and floor-layout UUIDs are retained.
-- Browser clients never receive a service-role credential; permissions are enforced by RLS below.

-- New order_status labels were committed by 20260723030000_add_order_status_values.sql.

alter table public.categories
  add column if not exists description text not null default '',
  add column if not exists color text,
  add column if not exists printer_destination text not null default 'internal' check (printer_destination in ('internal', 'none')),
  add column if not exists updated_at timestamptz not null default now();
alter table public.products
  add column if not exists description text not null default '',
  add column if not exists tax_rate numeric(5,2) not null default 0 check (tax_rate >= 0 and tax_rate <= 100),
  add column if not exists sku text,
  add column if not exists barcode text,
  add column if not exists image_url text,
  add column if not exists cost_price numeric(12,2) not null default 0 check (cost_price >= 0),
  add column if not exists printer_destination text not null default 'internal' check (printer_destination in ('internal', 'none')),
  add column if not exists track_inventory boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();
create unique index if not exists products_sku_unique on public.products (sku) where sku is not null;
create unique index if not exists products_barcode_unique on public.products (barcode) where barcode is not null;
create index if not exists categories_sort_active_idx on public.categories (active, sort_order);

alter table public.orders
  add column if not exists opened_by uuid references public.profiles(id) on delete restrict,
  add column if not exists assigned_worker uuid references public.profiles(id) on delete set null,
  add column if not exists guest_count integer check (guest_count is null or guest_count > 0),
  add column if not exists notes text not null default '',
  add column if not exists discount_total numeric(12,2) not null default 0 check (discount_total >= 0),
  add column if not exists tax_total numeric(12,2) not null default 0 check (tax_total >= 0),
  add column if not exists tip_total numeric(12,2) not null default 0 check (tip_total >= 0),
  add column if not exists amount_paid numeric(12,2) not null default 0 check (amount_paid >= 0),
  add column if not exists balance_due numeric(12,2) not null default 0 check (balance_due >= 0),
  add column if not exists internal_only boolean not null default false,
  add column if not exists internal_reason text,
  add column if not exists updated_at timestamptz not null default now();
update public.orders set opened_by = created_by where opened_by is null;
alter table public.orders alter column opened_by set not null;
-- Keep the old `closed` enum value readable while all new closures use `paid`.
alter table public.orders drop constraint if exists orders_closed_at_matches_status;
alter table public.orders add constraint orders_closed_at_matches_status check ((status::text in ('paid', 'closed', 'cancelled', 'voided')) = (closed_at is not null));
drop index if exists public.orders_one_open_order_per_table;
create unique index if not exists orders_one_active_order_per_table on public.orders(table_id) where status::text in ('open', 'sent', 'partially_paid', 'internal_only');

alter table public.order_items
  add column if not exists product_name_snapshot text,
  add column if not exists unit_price_snapshot numeric(12,2),
  add column if not exists tax_rate_snapshot numeric(5,2) not null default 0,
  add column if not exists sent_quantity integer not null default 0 check (sent_quantity >= 0),
  add column if not exists printed_quantity integer not null default 0 check (printed_quantity >= 0),
  add column if not exists course text,
  add column if not exists seat_number integer check (seat_number is null or seat_number > 0),
  add column if not exists line_discount numeric(12,2) not null default 0 check (line_discount >= 0),
  add column if not exists status text not null default 'active' check (status in ('active', 'voided', 'deleted')),
  add column if not exists deletion_reason text,
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_at timestamptz not null default now();
update public.order_items oi set product_name_snapshot = p.name, unit_price_snapshot = oi.price, tax_rate_snapshot = p.tax_rate
from public.products p where p.id = oi.product_id and oi.product_name_snapshot is null;
alter table public.order_items alter column product_name_snapshot set not null;
alter table public.order_items alter column unit_price_snapshot set not null;

create table if not exists public.table_reservations (
  id uuid primary key default gen_random_uuid(), table_object_id uuid not null, reserved_by uuid not null references public.profiles(id),
  reserved_for timestamptz, guest_name text, guest_count integer check (guest_count is null or guest_count > 0), notes text not null default '',
  released_at timestamptz, released_by uuid references public.profiles(id), created_at timestamptz not null default now()
);
create unique index if not exists one_active_reservation_per_floor_table on public.table_reservations(table_object_id) where released_at is null;

create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(), code text not null unique check (code ~ '^[a-z0-9_-]+$'), name text not null,
  enabled boolean not null default true, requires_fiscal boolean not null default true, sort_order integer not null default 0, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete restrict,
  payment_method_id uuid not null references public.payment_methods(id) on delete restrict, amount numeric(12,2) not null check (amount > 0),
  tip_amount numeric(12,2) not null default 0 check (tip_amount >= 0), tendered_amount numeric(12,2), change_due numeric(12,2) not null default 0 check (change_due >= 0),
  notes text not null default '', idempotency_key uuid not null unique, created_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
create table if not exists public.printers (
  id uuid primary key default gen_random_uuid(), name text not null unique, type text not null check (type in ('internal','fiscal')), enabled boolean not null default true,
  connection_method text not null default 'local_agent', ip_address inet, port integer check (port between 1 and 65535), device_identifier text, provider text,
  paper_width integer, character_encoding text, timeout_ms integer not null default 10000 check (timeout_ms > 0), retry_limit integer not null default 3 check (retry_limit >= 0), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.print_jobs (
  id uuid primary key default gen_random_uuid(), printer_id uuid references public.printers(id) on delete set null, order_id uuid references public.orders(id) on delete restrict,
  type text not null check (type in ('internal_ticket','internal_reprint','fiscal_receipt','fiscal_refund')), status text not null default 'pending' check (status in ('pending','processing','printed','failed','cancelled')),
  idempotency_key uuid not null unique, payload jsonb not null default '{}'::jsonb, failure_reason text, fiscal_receipt_number text, fiscal_device_response jsonb, created_by uuid references public.profiles(id), created_at timestamptz not null default now(), processed_at timestamptz
);
create table if not exists public.print_job_items (id uuid primary key default gen_random_uuid(), print_job_id uuid not null references public.print_jobs(id) on delete cascade, order_item_id uuid references public.order_items(id), quantity integer not null check (quantity > 0));
create table if not exists public.print_attempts (id uuid primary key default gen_random_uuid(), print_job_id uuid not null references public.print_jobs(id) on delete cascade, attempt_number integer not null check (attempt_number > 0), status text not null check (status in ('processing','printed','failed')), request_payload jsonb not null default '{}'::jsonb, response_payload jsonb, failure_reason text, attempted_at timestamptz not null default now(), unique(print_job_id, attempt_number));

create table if not exists public.audit_log (
 id bigint generated always as identity primary key, actor_id uuid references public.profiles(id) on delete set null, action text not null, entity_type text not null, entity_id text not null,
 before_data jsonb, after_data jsonb, reason text, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create index if not exists audit_log_entity_idx on public.audit_log(entity_type, entity_id, created_at desc);

create or replace function public.has_permission(required_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.role_permissions rp where rp.role = public.current_app_role() and rp.permission_key = required_permission)
$$;

-- The catalog is readable by POS users but edits require an explicit permission.
drop policy if exists "staff read catalog categories" on public.categories;
drop policy if exists "catalog read with orders permission" on public.categories;
drop policy if exists "catalog manage with permission" on public.categories;
drop policy if exists "staff read catalog products" on public.products;
drop policy if exists "products read with orders permission" on public.products;
drop policy if exists "products manage with permission" on public.products;
create policy "catalog read with orders permission" on public.categories for select to authenticated using (public.has_permission('orders:view'));
create policy "catalog manage with permission" on public.categories for all to authenticated using (public.has_permission('products:manage')) with check (public.has_permission('products:manage'));
create policy "products read with orders permission" on public.products for select to authenticated using (public.has_permission('orders:view'));
create policy "products manage with permission" on public.products for all to authenticated using (public.has_permission('products:manage')) with check (public.has_permission('products:manage'));

drop trigger if exists categories_updated_at on public.categories;
drop trigger if exists products_updated_at on public.products;
create trigger categories_updated_at before update on public.categories for each row execute procedure public.set_updated_at();
create trigger products_updated_at before update on public.products for each row execute procedure public.set_updated_at();

alter table public.table_reservations enable row level security;
drop policy if exists "reservations use with table permission" on public.table_reservations;
drop policy if exists "reservations read with orders permission" on public.table_reservations;
alter table public.payment_methods enable row level security;
drop policy if exists "payment methods read for payments" on public.payment_methods;
alter table public.payments enable row level security;
drop policy if exists "payments use with payment permission" on public.payments;
alter table public.printers enable row level security;
drop policy if exists "printers manage with permission" on public.printers;
alter table public.print_jobs enable row level security;
drop policy if exists "print jobs manage with permission" on public.print_jobs;
alter table public.print_job_items enable row level security;
drop policy if exists "print job items manage with permission" on public.print_job_items;
alter table public.print_attempts enable row level security;
drop policy if exists "print attempts manage with permission" on public.print_attempts;
alter table public.audit_log enable row level security;
drop policy if exists "admins read audit log" on public.audit_log;
create policy "reservations use with table permission" on public.table_reservations for all to authenticated using (public.has_permission('tables:reserve')) with check (public.has_permission('tables:reserve'));
create policy "payment methods read for payments" on public.payment_methods for select to authenticated using (public.has_permission('orders:pay'));
create policy "payments use with payment permission" on public.payments for all to authenticated using (public.has_permission('orders:pay')) with check (public.has_permission('orders:pay'));
create policy "printers manage with permission" on public.printers for all to authenticated using (public.has_permission('printers:manage')) with check (public.has_permission('printers:manage'));
create policy "print jobs manage with permission" on public.print_jobs for all to authenticated using (public.has_permission('printers:manage')) with check (public.has_permission('printers:manage'));
create policy "print job items manage with permission" on public.print_job_items for all to authenticated using (public.has_permission('printers:manage')) with check (public.has_permission('printers:manage'));
create policy "print attempts manage with permission" on public.print_attempts for all to authenticated using (public.has_permission('printers:manage')) with check (public.has_permission('printers:manage'));
create policy "admins read audit log" on public.audit_log for select to authenticated using (public.is_admin());

drop policy if exists "staff use orders" on public.orders;
drop policy if exists "orders read with permission" on public.orders;
drop policy if exists "orders create with permission" on public.orders;
drop policy if exists "orders edit with permission" on public.orders;
drop policy if exists "staff use order items" on public.order_items;
drop policy if exists "items read with order permission" on public.order_items;
drop policy if exists "items create with order permission" on public.order_items;
drop policy if exists "items edit with order permission" on public.order_items;
create policy "orders read with permission" on public.orders for select to authenticated using (public.has_permission('orders:view'));
create policy "orders create with permission" on public.orders for insert to authenticated with check (public.has_permission('orders:create') and created_by = auth.uid());
create policy "orders edit with permission" on public.orders for update to authenticated using (public.has_permission('orders:edit')) with check (public.has_permission('orders:edit'));
create policy "items read with order permission" on public.order_items for select to authenticated using (public.has_permission('orders:view'));
create policy "items create with order permission" on public.order_items for insert to authenticated with check (public.has_permission('orders:edit'));
create policy "items edit with order permission" on public.order_items for update to authenticated using (public.has_permission('orders:edit')) with check (public.has_permission('orders:edit'));

insert into public.permissions(key, description) values
 ('orders:view','View orders'), ('orders:create','Create orders'), ('orders:edit','Edit orders'), ('orders:pay','Take payments'),
 ('products:manage','Manage products and categories'), ('inventory:manage','Manage inventory'), ('staff:manage','Manage staff'), ('shifts:manage','Manage shifts'),
 ('reports:operational','View operational reports'), ('reports:financial','View financial reports'), ('printers:manage','Manage and retry print jobs'),
 ('floor_plan:edit','Edit floor plan'), ('tables:reserve','Reserve tables'), ('tables:transfer','Transfer or merge tables'), ('settings:manage','Manage settings')
on conflict (key) do update set description = excluded.description;
insert into public.role_permissions(role, permission_key)
select 'admin'::public.app_role, key from public.permissions on conflict do nothing;
insert into public.role_permissions(role, permission_key) values
 ('manager','orders:view'),('manager','orders:create'),('manager','orders:edit'),('manager','orders:pay'),('manager','products:manage'),('manager','inventory:manage'),('manager','staff:manage'),('manager','shifts:manage'),('manager','reports:operational'),('manager','printers:manage'),('manager','tables:reserve'),('manager','tables:transfer'),
 ('worker','orders:view'),('worker','orders:create'),('worker','orders:edit'),('worker','orders:pay') on conflict do nothing;

-- Local print agents claim pending jobs and acknowledge real device outcomes. They must never mark a job printed without a device response.
comment on table public.print_jobs is 'Queue consumed by an authenticated local print agent. Payload contains ticket data and idempotency_key; agent acknowledges printed or failed and records a print_attempt.';

-- Reopening includes every active state, not just draft orders.  The partial unique index is the final concurrency guard.
create or replace function public.open_order_for_table(target_table_id uuid)
returns public.orders language plpgsql security definer set search_path = public as $$
declare result public.orders;
begin
  if auth.uid() is null or not public.has_permission('orders:create') then raise exception 'Not authorized to open orders'; end if;
  perform 1 from public.floor_layouts where id = 1
    and jsonb_path_exists(layout, '$.** ? ((@.id == $table_id || @.uuid == $table_id || @.objectId == $table_id) && (@.type like_regex ".*table.*" flag "i" || @.objectType like_regex ".*table.*" flag "i" || @.kind like_regex ".*table.*" flag "i" || @.tableType like_regex ".*table.*" flag "i" || @.tableShape like_regex "^(round|square|rectangle|rectangular)$" flag "i" || @.shape like_regex "^(round|square|rectangle|rectangular)(-table)?$" flag "i"))', jsonb_build_object('table_id', to_jsonb(target_table_id::text)))
    for update;
  if not found then raise exception 'Floor table not found'; end if;
  select * into result from public.orders where table_id = target_table_id and status::text in ('open', 'sent', 'partially_paid', 'internal_only') for update;
  if found then return result; end if;
  insert into public.orders (table_id, created_by, opened_by) values (target_table_id, auth.uid(), auth.uid()) returning * into result;
  return result;
end;
$$;
create policy "reservations read with orders permission" on public.table_reservations for select to authenticated using (public.has_permission('orders:view'));
-- Keep payment, final order status, table release, and fiscal queueing in one transaction.
-- This prevents the closed_at/status constraint from seeing an intermediate state.
create or replace function public.record_order_payment(
  target_order_id uuid,
  target_payment_method_id uuid,
  payment_amount numeric,
  tendered_amount numeric,
  payment_change_due numeric,
  payment_idempotency_key uuid
)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.orders;
  method_requires_fiscal boolean;
  computed_subtotal numeric(12,2);
  computed_tax numeric(12,2);
  computed_total numeric(12,2);
  new_amount_paid numeric(12,2);
  is_fully_paid boolean;
begin
  if auth.uid() is null or not public.has_permission('orders:pay') then
    raise exception 'You are not allowed to record payments.';
  end if;
  if payment_amount <= 0 then
    raise exception 'Payment amount must be greater than zero.';
  end if;

  select * into result from public.orders where id = target_order_id for update;
  if not found then raise exception 'Order was not found.'; end if;
  if result.status::text not in ('open', 'sent', 'partially_paid') or result.closed_at is not null or result.internal_only then
    raise exception 'This order cannot accept a payment.';
  end if;

  select requires_fiscal into method_requires_fiscal
  from public.payment_methods
  where id = target_payment_method_id and enabled;
  if not found then raise exception 'Select an enabled payment method.'; end if;

  select
    coalesce(sum(quantity * unit_price_snapshot - line_discount), 0),
    coalesce(sum((quantity * unit_price_snapshot - line_discount) * tax_rate_snapshot / 100), 0)
  into computed_subtotal, computed_tax
  from public.order_items
  where order_id = target_order_id and deleted_at is null and status = 'active';
  computed_total := computed_subtotal + computed_tax;
  new_amount_paid := result.amount_paid + payment_amount;

  insert into public.payments (
    order_id, payment_method_id, amount, tendered_amount, change_due, idempotency_key, created_by
  ) values (
    target_order_id, target_payment_method_id, payment_amount, tendered_amount, payment_change_due,
    payment_idempotency_key, auth.uid()
  );

  is_fully_paid := new_amount_paid >= computed_total;
  update public.orders
  set subtotal = computed_subtotal,
      tax_total = computed_tax,
      total = computed_total,
      amount_paid = new_amount_paid,
      balance_due = greatest(computed_total - new_amount_paid, 0),
      status = case when is_fully_paid then 'paid'::public.order_status else 'partially_paid'::public.order_status end,
      closed_at = case when is_fully_paid then now() else null end
  where id = target_order_id
  returning * into result;

  if is_fully_paid and method_requires_fiscal then
    insert into public.print_jobs (order_id, type, status, idempotency_key, payload, created_by)
    values (
      target_order_id, 'fiscal_receipt', 'pending', gen_random_uuid(),
      jsonb_build_object('order_id', target_order_id, 'total', computed_total, 'amount_paid', new_amount_paid, 'non_fiscal', false),
      auth.uid()
    );
  end if;

  return result;
end;
$$;

create or replace function public.mark_order_internal_only(target_order_id uuid)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare result public.orders;
begin
  if auth.uid() is null or not public.has_permission('orders:pay') then
    raise exception 'You are not allowed to mark orders as internal-only.';
  end if;
  update public.orders
  set status = 'internal_only', internal_only = true, closed_at = null
  where id = target_order_id and status::text in ('open', 'sent', 'partially_paid') and closed_at is null
  returning * into result;
  if not found then raise exception 'This order cannot be marked as internal-only.'; end if;
  return result;
end;
$$;

create or replace function public.queue_internal_print_job(target_order_id uuid, job_payload jsonb, job_items jsonb)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.orders;
  new_job_id uuid;
  item jsonb;
begin
  if auth.uid() is null or not public.has_permission('orders:edit') then
    raise exception 'You are not allowed to send internal tickets.';
  end if;
  select * into result from public.orders where id = target_order_id for update;
  if not found or result.status::text not in ('open', 'sent', 'partially_paid', 'internal_only') or result.closed_at is not null then
    raise exception 'This order cannot be sent internally.';
  end if;

  insert into public.print_jobs (order_id, type, status, idempotency_key, payload, created_by)
  values (target_order_id, 'internal_ticket', 'pending', gen_random_uuid(), job_payload || jsonb_build_object('non_fiscal', true), auth.uid())
  returning id into new_job_id;

  for item in select value from jsonb_array_elements(job_items)
  loop
    insert into public.print_job_items (print_job_id, order_item_id, quantity)
    values (new_job_id, (item->>'order_item_id')::uuid, (item->>'quantity')::integer);
    update public.order_items
    set sent_quantity = sent_quantity + (item->>'quantity')::integer
    where id = (item->>'order_item_id')::uuid and order_id = target_order_id;
    if not found then raise exception 'An item in this ticket no longer belongs to the order.'; end if;
  end loop;

  if result.status = 'open'::public.order_status then
    update public.orders set status = 'sent', closed_at = null where id = target_order_id returning * into result;
  end if;
  return result;
end;
$$;

grant execute on function public.record_order_payment(uuid, uuid, numeric, numeric, numeric, uuid) to authenticated;
grant execute on function public.mark_order_internal_only(uuid) to authenticated;
grant execute on function public.queue_internal_print_job(uuid, jsonb, jsonb) to authenticated;

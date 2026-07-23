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

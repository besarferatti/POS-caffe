-- Internal-only orders are completed orders: they must not retain a table or
-- participate in the active-order concurrency guard.
update public.orders
set internal_only = true,
    internal_reason = coalesce(nullif(btrim(internal_reason), ''), 'Legacy internal-only completion'),
    closed_at = coalesce(closed_at, now())
where status::text = 'internal_only';

alter table public.orders drop constraint if exists orders_closed_at_matches_status;
alter table public.orders add constraint orders_closed_at_matches_status
  check ((status::text in ('paid', 'closed', 'cancelled', 'voided', 'internal_only')) = (closed_at is not null));
alter table public.orders drop constraint if exists orders_internal_only_requires_reason;
alter table public.orders add constraint orders_internal_only_requires_reason
  check (status::text <> 'internal_only' or (internal_only and nullif(btrim(internal_reason), '') is not null));

drop index if exists public.orders_one_active_order_per_table;
create unique index orders_one_active_order_per_table
  on public.orders(table_id)
  where status::text in ('open', 'sent', 'partially_paid');

-- Replaces the prior active-order lookup so completed internal-only orders
-- cannot be resumed when a table is selected.
create or replace function public.open_order_for_table(target_table_id uuid)
returns public.orders language plpgsql security definer set search_path = public as $$
declare result public.orders;
begin
  if auth.uid() is null or not public.has_permission('orders:create') then raise exception 'Not authorized to open orders'; end if;
  perform 1 from public.floor_layouts where id = 1
    and jsonb_path_exists(layout, '$.** ? ((@.id == $table_id || @.uuid == $table_id || @.objectId == $table_id) && (@.type like_regex ".*table.*" flag "i" || @.objectType like_regex ".*table.*" flag "i" || @.kind like_regex ".*table.*" flag "i" || @.tableType like_regex ".*table.*" flag "i" || @.tableShape like_regex "^(round|square|rectangle|rectangular)$" flag "i" || @.shape like_regex "^(round|square|rectangle|rectangular)(-table)?$" flag "i"))', jsonb_build_object('table_id', to_jsonb(target_table_id::text)))
    for update;
  if not found then raise exception 'Floor table not found'; end if;
  select * into result from public.orders
  where table_id = target_table_id and status::text in ('open', 'sent', 'partially_paid')
  for update;
  if found then return result; end if;
  insert into public.orders (table_id, created_by, opened_by)
  values (target_table_id, auth.uid(), auth.uid()) returning * into result;
  return result;
end;
$$;

-- Finalize, release, and queue exactly one non-fiscal ticket in one transaction.
create or replace function public.complete_order_internal_only(
  target_order_id uuid,
  reason text,
  job_payload jsonb,
  job_items jsonb
)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.orders;
  computed_subtotal numeric(12,2);
  computed_tax numeric(12,2);
  computed_total numeric(12,2);
  new_job_id uuid;
  item jsonb;
begin
  if auth.uid() is null or not public.has_permission('orders:pay') then
    raise exception 'You are not allowed to complete orders as internal-only.';
  end if;
  if nullif(btrim(reason), '') is null then
    raise exception 'An internal-only reason is required.';
  end if;

  select * into result from public.orders where id = target_order_id for update;
  if not found or result.status::text not in ('open', 'sent', 'partially_paid') or result.closed_at is not null then
    raise exception 'This order cannot be completed as internal-only.';
  end if;

  select coalesce(sum(quantity * unit_price_snapshot - line_discount), 0),
         coalesce(sum((quantity * unit_price_snapshot - line_discount) * tax_rate_snapshot / 100), 0)
  into computed_subtotal, computed_tax
  from public.order_items
  where order_id = target_order_id and deleted_at is null and status = 'active';
  computed_total := computed_subtotal + computed_tax;

  update public.orders
  set status = 'internal_only', internal_only = true, internal_reason = btrim(reason),
      subtotal = computed_subtotal, tax_total = computed_tax, total = computed_total,
      balance_due = greatest(computed_total - amount_paid, 0), closed_at = now()
  where id = target_order_id
  returning * into result;

  insert into public.print_jobs (order_id, type, status, idempotency_key, payload, created_by)
  values (target_order_id, 'internal_ticket', 'pending', gen_random_uuid(),
          coalesce(job_payload, '{}'::jsonb) || jsonb_build_object('non_fiscal', true, 'internal_only', true, 'internal_reason', btrim(reason)), auth.uid())
  returning id into new_job_id;

  for item in select value from jsonb_array_elements(coalesce(job_items, '[]'::jsonb))
  loop
    insert into public.print_job_items (print_job_id, order_item_id, quantity)
    values (new_job_id, (item->>'order_item_id')::uuid, (item->>'quantity')::integer);
    update public.order_items
    set sent_quantity = sent_quantity + (item->>'quantity')::integer
    where id = (item->>'order_item_id')::uuid and order_id = target_order_id
      and deleted_at is null and status = 'active';
    if not found then raise exception 'An item in this ticket no longer belongs to the order.'; end if;
  end loop;
  return result;
end;
$$;

revoke execute on function public.mark_order_internal_only(uuid) from authenticated;
grant execute on function public.complete_order_internal_only(uuid, text, jsonb, jsonb) to authenticated;

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

-- Simple, product-level inventory. Legacy recipe/purchase tables remain untouched for historical data.
alter table public.products add column if not exists track_inventory boolean not null default false;
alter table public.products add column if not exists stock_quantity numeric(14,3) not null default 0;
alter table public.products add column if not exists low_stock_threshold numeric(14,3) not null default 0;
alter table public.products add column if not exists allow_negative_stock boolean not null default false;
alter table public.products drop constraint if exists products_stock_quantity_nonnegative;
alter table public.products add constraint products_stock_quantity_nonnegative check (allow_negative_stock or stock_quantity >= 0);
alter table public.products drop constraint if exists products_low_stock_threshold_nonnegative;
alter table public.products add constraint products_low_stock_threshold_nonnegative check (low_stock_threshold >= 0);
create index if not exists products_inventory_category_idx on public.products(category_id) where track_inventory;

create table if not exists public.product_stock_movements (
 id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id) on delete restrict,
 movement_type text not null check (movement_type in ('sale','sale_reversal','adjustment_add','adjustment_remove','adjustment_set')),
 quantity_change numeric(14,3) not null, stock_before numeric(14,3) not null, stock_after numeric(14,3) not null,
 order_id uuid references public.orders(id) on delete restrict, order_item_id uuid references public.order_items(id) on delete restrict,
 reason text, created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(),
 idempotency_key text not null unique, check (stock_after = stock_before + quantity_change)
);
create index if not exists product_stock_movements_product_created_idx on public.product_stock_movements(product_id, created_at desc);
create index if not exists product_stock_movements_order_idx on public.product_stock_movements(order_id) where order_id is not null;
alter table public.product_stock_movements enable row level security;
drop policy if exists product_stock_movements_read on public.product_stock_movements;
create policy product_stock_movements_read on public.product_stock_movements for select to authenticated using (public.user_has_permission('inventory:manage'));

create or replace function public.adjust_product_stock(p_product_id uuid, p_adjustment_type text, p_quantity numeric, p_reason text, p_idempotency_key text default null)
returns public.products language plpgsql security definer set search_path=public as $$
declare p public.products; delta numeric; movement text; key text := coalesce(nullif(btrim(p_idempotency_key), ''), 'adjustment:' || gen_random_uuid()::text); begin
 if auth.uid() is null or not public.user_has_permission('inventory:manage') then raise exception 'You do not have permission to manage inventory.'; end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'A reason is required.'; end if;
 if p_quantity < 0 then raise exception 'Quantity cannot be negative.'; end if;
 select * into p from public.products where id=p_product_id for update; if not found then raise exception 'Product not found.'; end if;
 if p_adjustment_type='add' then delta:=p_quantity; movement:='adjustment_add'; elsif p_adjustment_type='remove' then delta:=-p_quantity; movement:='adjustment_remove'; elsif p_adjustment_type='set' then delta:=p_quantity-p.stock_quantity; movement:='adjustment_set'; else raise exception 'Invalid adjustment type.'; end if;
 if p.stock_quantity + delta < 0 and not p.allow_negative_stock then raise exception 'Stock cannot go below zero for %.', p.name; end if;
 insert into public.product_stock_movements(product_id,movement_type,quantity_change,stock_before,stock_after,reason,created_by,idempotency_key) values(p.id,movement,delta,p.stock_quantity,p.stock_quantity+delta,btrim(p_reason),auth.uid(),key) on conflict(idempotency_key) do nothing;
 if not found then return p; end if;
 update public.products set stock_quantity=stock_quantity+delta where id=p.id returning * into p; return p;
end $$;

create or replace function public.deduct_paid_order_stock(p_order_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare i record; p public.products; key text; begin
 for i in select id,product_id,quantity from public.order_items where order_id=p_order_id and deleted_at is null and status='active' loop
  select * into p from public.products where id=i.product_id for update; if not found or not p.track_inventory then continue; end if;
  key := 'sale:' || p_order_id::text || ':' || i.id::text;
  if exists(select 1 from public.product_stock_movements where idempotency_key=key) then continue; end if;
  if p.stock_quantity < i.quantity and not p.allow_negative_stock then raise exception 'Not enough stock for %. Available: %, required: %.', p.name, p.stock_quantity, i.quantity; end if;
  insert into public.product_stock_movements(product_id,movement_type,quantity_change,stock_before,stock_after,order_id,order_item_id,reason,created_by,idempotency_key) values(p.id,'sale',-i.quantity,p.stock_quantity,p.stock_quantity-i.quantity,p_order_id,i.id,'Paid sale',auth.uid(),key);
  update public.products set stock_quantity=stock_quantity-i.quantity where id=p.id;
 end loop;
end $$;

create or replace function public.reverse_paid_order_stock(p_order_id uuid, p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare m record; p public.products; key text; begin
 if auth.uid() is null or not public.user_has_permission('orders:pay') then raise exception 'You are not allowed to reverse sales.'; end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'A reason is required.'; end if;
 for m in select * from public.product_stock_movements where order_id=p_order_id and movement_type='sale' loop
  key := 'sale-reversal:' || m.id::text; if exists(select 1 from public.product_stock_movements where idempotency_key=key) then continue; end if;
  select * into p from public.products where id=m.product_id for update;
  insert into public.product_stock_movements(product_id,movement_type,quantity_change,stock_before,stock_after,order_id,order_item_id,reason,created_by,idempotency_key) values(p.id,'sale_reversal',-m.quantity_change,p.stock_quantity,p.stock_quantity-m.quantity_change,p_order_id,m.order_item_id,btrim(p_reason),auth.uid(),key);
  update public.products set stock_quantity=stock_quantity-m.quantity_change where id=p.id;
 end loop;
end $$;

-- Replaces the payment routine so the final paid transition and product deductions are one transaction.
create or replace function public.record_order_payment(target_order_id uuid,target_payment_method_id uuid,payment_amount numeric,tendered_amount numeric,payment_change_due numeric,payment_idempotency_key uuid)
returns public.orders language plpgsql security definer set search_path=public as $$
declare result public.orders; method_requires_fiscal boolean; computed_subtotal numeric(12,2); computed_tax numeric(12,2); computed_total numeric(12,2); new_amount_paid numeric(12,2); is_fully_paid boolean; begin
 if auth.uid() is null or not public.has_permission('orders:pay') then raise exception 'You are not allowed to record payments.'; end if;
 if payment_amount<=0 then raise exception 'Payment amount must be greater than zero.'; end if;
 select * into result from public.orders where id=target_order_id for update; if not found or result.status::text not in ('open','sent','partially_paid') or result.closed_at is not null or result.internal_only then raise exception 'This order cannot accept a payment.'; end if;
 select requires_fiscal into method_requires_fiscal from public.payment_methods where id=target_payment_method_id and enabled; if not found then raise exception 'Select an enabled payment method.'; end if;
 select coalesce(sum(quantity*unit_price_snapshot-line_discount),0),coalesce(sum((quantity*unit_price_snapshot-line_discount)*tax_rate_snapshot/100),0) into computed_subtotal,computed_tax from public.order_items where order_id=target_order_id and deleted_at is null and status='active'; computed_total:=computed_subtotal+computed_tax; new_amount_paid:=result.amount_paid+payment_amount; is_fully_paid:=new_amount_paid>=computed_total;
 insert into public.payments(order_id,payment_method_id,amount,tendered_amount,change_due,idempotency_key,created_by) values(target_order_id,target_payment_method_id,payment_amount,tendered_amount,payment_change_due,payment_idempotency_key,auth.uid());
 if is_fully_paid then perform public.deduct_paid_order_stock(target_order_id); end if;
 update public.orders set subtotal=computed_subtotal,tax_total=computed_tax,total=computed_total,amount_paid=new_amount_paid,balance_due=greatest(computed_total-new_amount_paid,0),status=case when is_fully_paid then 'paid'::public.order_status else 'partially_paid'::public.order_status end,closed_at=case when is_fully_paid then now() else null end where id=target_order_id returning * into result;
 if is_fully_paid and method_requires_fiscal then insert into public.print_jobs(order_id,type,status,idempotency_key,payload,created_by) values(target_order_id,'fiscal_receipt','pending',gen_random_uuid(),jsonb_build_object('order_id',target_order_id,'total',computed_total,'amount_paid',new_amount_paid,'non_fiscal',false),auth.uid()); end if; return result;
end $$;
grant execute on function public.adjust_product_stock(uuid,text,numeric,text,text), public.deduct_paid_order_stock(uuid), public.reverse_paid_order_stock(uuid,text), public.record_order_payment(uuid,uuid,numeric,numeric,numeric,uuid) to authenticated;

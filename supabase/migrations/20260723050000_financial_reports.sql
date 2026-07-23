-- Reporting API: all aggregates execute in PostgreSQL and are permission-gated.
create index if not exists reports_orders_closed_at_idx on public.orders (closed_at desc) where status::text in ('paid','closed','internal_only');
create index if not exists reports_orders_opened_at_idx on public.orders (opened_at desc);
create index if not exists reports_payments_created_at_idx on public.payments (created_at desc, order_id);
create index if not exists reports_order_items_order_idx on public.order_items (order_id, product_id) where deleted_at is null and status = 'active';
create index if not exists reports_print_jobs_order_status_idx on public.print_jobs (order_id, status, type);

create or replace function public.reporting_dashboard(
  range_start timestamptz, range_end timestamptz,
  staff_id uuid default null, method_id uuid default null, category_id uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
declare can_financial boolean;
begin
  can_financial := public.user_has_permission('reports:financial');
  if auth.uid() is null or not (public.user_has_permission('reports:operational') or can_financial) then
    raise exception 'Not authorized to view reports';
  end if;
  if range_start is null or range_end is null or range_end <= range_start then raise exception 'Invalid reporting date range'; end if;
  with scoped as (
    select o.*, dt.name table_label, coalesce(p.display_name, 'Unassigned') worker
    from public.orders o join public.dining_tables dt on dt.id=o.table_id left join public.profiles p on p.id=coalesce(o.assigned_worker,o.opened_by,o.created_by)
    where o.opened_at >= range_start and o.opened_at < range_end and (staff_id is null or coalesce(o.assigned_worker,o.opened_by,o.created_by)=staff_id)
      and (category_id is null or exists (select 1 from public.order_items oi join public.products pr on pr.id=oi.product_id where oi.order_id=o.id and pr.category_id=category_id))
  ), paid_payments as (
    select py.*, pm.name method_name, pm.code method_code from public.payments py join public.payment_methods pm on pm.id=py.payment_method_id join scoped o on o.id=py.order_id
    where (method_id is null or py.payment_method_id=method_id)
  ), paid_orders as (select * from scoped where status::text in ('paid','closed') and not internal_only),
  product_sales as (
    select oi.product_name_snapshot name, sum(oi.quantity) quantity, sum(oi.quantity*oi.unit_price_snapshot-oi.line_discount) sales
    from public.order_items oi join paid_orders o on o.id=oi.order_id join public.products pr on pr.id=oi.product_id
    where oi.deleted_at is null and oi.status='active' and (category_id is null or pr.category_id=category_id) group by 1 order by sales desc
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'gross_sales',coalesce((select sum(subtotal+tax_total+tip_total) from paid_orders),0), 'net_sales',coalesce((select sum(subtotal+tax_total) from paid_orders),0),
      'total_payments',coalesce((select sum(amount) from paid_payments),0),'cash_sales',coalesce((select sum(amount) from paid_payments where method_code='cash'),0),'card_sales',coalesce((select sum(amount) from paid_payments where method_code in ('card','credit_card','debit_card')),0),
      'mixed_payments',coalesce((select sum(amount_paid) from paid_orders where (select count(*) from public.payments p where p.order_id=paid_orders.id)>1),0),
      'complimentary_total',coalesce((select sum(discount_total) from paid_orders),0),'internal_only_total',coalesce((select sum(total) from scoped where internal_only),0),
      'discounts',coalesce((select sum(discount_total) from paid_orders),0),'taxes',coalesce((select sum(tax_total) from paid_orders),0),'tips',coalesce((select sum(tip_amount) from paid_payments),0),'refunds',0,
      'average_order_value',coalesce((select avg(total) from paid_orders),0),'paid_orders',(select count(*) from paid_orders),'cancelled_orders',(select count(*) from scoped where status::text in ('cancelled','voided')),
      'outstanding_balance',coalesce((select sum(balance_due) from scoped where status::text in ('open','sent','partially_paid')),0),'sales_today',coalesce((select sum(amount) from paid_payments where created_at >= date_trunc('day', now())),0)),
    'sales_by_day',coalesce((select jsonb_agg(x order by x->>'day') from (select jsonb_build_object('day',to_char(created_at::date,'YYYY-MM-DD'),'sales',sum(amount),'payments',count(*)) x from paid_payments group by created_at::date) s),'[]'),
    'sales_by_hour',coalesce((select jsonb_agg(x order by x->>'hour') from (select jsonb_build_object('hour',extract(hour from created_at),'sales',sum(amount)) x from paid_payments group by extract(hour from created_at)) s),'[]'),
    'payment_methods',coalesce((select jsonb_agg(x order by (x->>'sales')::numeric desc) from (select jsonb_build_object('name',method_name,'sales',sum(amount),'payments',count(*)) x from paid_payments group by method_name) s),'[]'),
    'products',coalesce((select jsonb_agg(jsonb_build_object('name',name,'quantity',quantity,'sales',sales)) from product_sales),'[]'),
    'categories',coalesce((select jsonb_agg(x order by (x->>'sales')::numeric desc) from (select jsonb_build_object('name',c.name,'quantity',sum(oi.quantity),'sales',sum(oi.quantity*oi.unit_price_snapshot-oi.line_discount)) x from public.order_items oi join paid_orders o on o.id=oi.order_id join public.products pr on pr.id=oi.product_id join public.categories c on c.id=pr.category_id where oi.deleted_at is null and oi.status='active' group by c.name) s),'[]'),
    'employees',coalesce((select jsonb_agg(x) from (select jsonb_build_object('name',worker,'orders',count(*),'sales',sum(amount_paid)) x from paid_orders group by worker) s),'[]'),
    'tables',coalesce((select jsonb_agg(x) from (select jsonb_build_object('name',table_label,'orders',count(*),'sales',sum(amount_paid)) x from paid_orders group by table_label) s),'[]'),
    'orders',coalesce((select jsonb_agg(jsonb_build_object('id',id,'table',table_label,'worker',worker,'opened_at',opened_at,'closed_at',closed_at,'status',status::text,'total',total,'paid',amount_paid,'balance',balance_due,'internal_reason',internal_reason) order by opened_at desc) from scoped),'[]'),
    'operations',jsonb_build_object('open_orders',(select count(*) from scoped where status::text in ('open','sent','partially_paid')),'occupied_tables',(select count(*) from public.dining_tables where status='occupied'),'available_tables',(select count(*) from public.dining_tables where status='available'),'reserved_tables',(select count(*) from public.dining_tables where status='reserved'),'waiting_internal_print',(select count(*) from public.print_jobs where type like 'internal%' and status in ('pending','processing')),'failed_internal_print',(select count(*) from public.print_jobs where type like 'internal%' and status='failed'),'failed_fiscal_print',(select count(*) from public.print_jobs where type like 'fiscal%' and status='failed'),'voided_items',(select count(*) from public.order_items oi join scoped o on o.id=oi.order_id where oi.status='voided' or oi.deleted_at is not null),'internal_only_orders',(select count(*) from scoped where internal_only))
  ) into result;
  if not can_financial then
    result := jsonb_build_object('operations', result->'operations', 'orders', (select coalesce(jsonb_agg(x - 'total' - 'paid' - 'balance'), '[]'::jsonb) from jsonb_array_elements(result->'orders') x));
  end if;
  return result;
end $$;
revoke all on function public.reporting_dashboard(timestamptz,timestamptz,uuid,uuid,uuid) from public;
grant execute on function public.reporting_dashboard(timestamptz,timestamptz,uuid,uuid,uuid) to authenticated;

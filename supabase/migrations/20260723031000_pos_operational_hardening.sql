-- Keep the one-open-order invariant compatible with the order_status enum.
drop index if exists public.orders_one_open_order_per_table;
drop index if exists public.orders_one_active_order_per_table;

create unique index orders_one_open_order_per_table
  on public.orders (table_id)
  where status = 'open'::public.order_status;

-- Return the existing open order when a table is selected again.
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

  select * into result from public.orders
    where table_id = target_table_id
      and status = 'open'::public.order_status
    for update;
  if found then return result; end if;

  insert into public.orders (table_id, created_by)
    values (target_table_id, auth.uid())
    returning * into result;
  return result;
end;
$$;

grant execute on function public.open_order_for_table(uuid) to authenticated;

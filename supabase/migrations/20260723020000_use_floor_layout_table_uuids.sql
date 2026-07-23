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

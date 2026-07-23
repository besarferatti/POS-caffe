-- Phase 2: a shared, complete floor-plan document for the venue.
create table public.floor_layouts (
  id smallint primary key default 1 check (id = 1),
  layout jsonb not null default '{"objects":[],"viewport":{"x":0,"y":0,"scale":1}}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null
);

alter table public.floor_layouts enable row level security;

create policy "authenticated users read floor layout" on public.floor_layouts
  for select to authenticated using (true);
create policy "admins insert floor layout" on public.floor_layouts
  for insert to authenticated with check (public.is_admin());
create policy "admins update floor layout" on public.floor_layouts
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create trigger floor_layouts_updated_at before update on public.floor_layouts
  for each row execute procedure public.set_updated_at();

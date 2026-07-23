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

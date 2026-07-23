-- Staff management additions. This migration is intentionally additive.
create extension if not exists pgcrypto with schema extensions;

alter table public.profiles
  add column if not exists active boolean not null default true,
  add column if not exists pin_hash text,
  add column if not exists must_change_password boolean not null default false;

create table public.user_permissions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  permission_key text not null references public.permissions(key) on delete cascade,
  granted boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, permission_key)
);

create table public.staff_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  target_user_id uuid references public.profiles(id) on delete restrict,
  action text not null check (action in ('staff_created', 'staff_activated', 'staff_deactivated', 'role_changed', 'permissions_changed', 'pin_set', 'pin_reset', 'password_reset_requested', 'temporary_password_set')),
  before_data jsonb,
  after_data jsonb,
  reason text,
  created_at timestamptz not null default now()
);

create index user_permissions_user_id_idx on public.user_permissions(user_id);
create index staff_audit_log_target_created_idx on public.staff_audit_log(target_user_id, created_at desc);
create index profiles_active_role_idx on public.profiles(active, role);

insert into public.permissions(key, description) values
 ('orders:view','View orders'), ('orders:create','Create orders'), ('orders:edit','Edit orders'), ('orders:pay','Take payments'),
 ('products:manage','Manage products'), ('inventory:manage','Manage inventory'), ('staff:manage','Manage staff'),
 ('shifts:manage','Manage shifts'), ('reports:operational','View operational reports'), ('reports:financial','View financial reports'),
 ('printers:manage','Manage printers'), ('floor_plan:edit','Edit floor plan'), ('tables:reserve','Reserve tables'),
 ('tables:transfer','Transfer tables'), ('settings:manage','Manage settings')
on conflict (key) do update set description = excluded.description;

insert into public.role_permissions(role, permission_key)
select 'admin'::public.app_role, key from public.permissions on conflict do nothing;
insert into public.role_permissions(role, permission_key) values
 ('manager','orders:view'), ('manager','orders:create'), ('manager','orders:edit'), ('manager','orders:pay'),
 ('manager','products:manage'), ('manager','inventory:manage'), ('manager','shifts:manage'), ('manager','reports:operational'),
 ('manager','printers:manage'), ('manager','floor_plan:edit'), ('manager','tables:reserve'), ('manager','tables:transfer'),
 ('worker','orders:view'), ('worker','orders:create'), ('worker','orders:edit'), ('worker','orders:pay')
on conflict do nothing;

create or replace function public.user_has_permission(required_permission text, checked_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.profiles p
    where p.id = checked_user_id and p.active and (
      p.role = 'admin' or coalesce((select up.granted from public.user_permissions up where up.user_id = p.id and up.permission_key = required_permission),
        exists(select 1 from public.role_permissions rp where rp.role = p.role and rp.permission_key = required_permission))
    )
  );
$$;

create or replace function public.validate_staff_pin(candidate text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
 select exists(select 1 from public.profiles where id = auth.uid() and active and pin_hash is not null and pin_hash = extensions.crypt(candidate, pin_hash));
$$;
create or replace function public.hash_staff_pin(candidate text)
returns text language sql volatile security definer set search_path = public, extensions as $$
 select extensions.crypt(candidate, extensions.gen_salt('bf'));
$$;

create or replace function public.prevent_last_active_admin()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if old.role = 'admin' and old.active and (new.role <> 'admin' or not new.active)
    and (select count(*) from public.profiles where role = 'admin' and active and id <> old.id) = 0 then
    raise exception 'The last active administrator cannot be deactivated or lose the administrator role';
  end if;
  return new;
end;
$$;
create trigger profiles_prevent_last_active_admin before update of role, active on public.profiles for each row execute procedure public.prevent_last_active_admin();

alter table public.user_permissions enable row level security;
alter table public.staff_audit_log enable row level security;
create trigger user_permissions_updated_at before update on public.user_permissions for each row execute procedure public.set_updated_at();
drop policy if exists "users read own profile or manager reads staff" on public.profiles;
create policy "staff managers read profiles" on public.profiles for select to authenticated using (id = auth.uid() or public.user_has_permission('staff:manage'));
create policy "staff managers read user permissions" on public.user_permissions for select to authenticated using (user_id = auth.uid() or public.user_has_permission('staff:manage'));
create policy "staff managers read audit" on public.staff_audit_log for select to authenticated using (public.user_has_permission('staff:manage'));
revoke all on function public.user_has_permission(text, uuid) from public;
revoke all on function public.validate_staff_pin(text) from public;
revoke all on function public.hash_staff_pin(text) from public;
grant execute on function public.user_has_permission(text, uuid) to authenticated;
grant execute on function public.validate_staff_pin(text) to authenticated;

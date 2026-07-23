-- Seed the canonical permission matrix. Auth users can be created through Supabase Auth;
-- every new user receives the worker role via the migration trigger.
insert into public.permissions (key, description) values
  ('staff:read', 'View staff profiles'),
  ('staff:manage', 'Manage staff roles'),
  ('settings:manage', 'Manage application settings'),
  ('pos:use', 'Access the point-of-sale workspace')
on conflict (key) do update set description = excluded.description;

insert into public.role_permissions (role, permission_key) values
  ('admin', 'staff:read'), ('admin', 'staff:manage'), ('admin', 'settings:manage'), ('admin', 'pos:use'),
  ('manager', 'staff:read'), ('manager', 'pos:use'),
  ('worker', 'pos:use')
on conflict do nothing;

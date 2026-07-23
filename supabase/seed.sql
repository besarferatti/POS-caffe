-- Seed the canonical permission matrix. Auth users are created through Supabase Auth.
insert into public.permissions (key, description) values
  ('staff:read', 'View staff profiles'), ('staff:manage', 'Manage staff roles'),
  ('settings:manage', 'Manage application settings'), ('pos:use', 'Access the point-of-sale workspace')
on conflict (key) do update set description = excluded.description;
insert into public.role_permissions (role, permission_key) values
  ('admin', 'staff:read'), ('admin', 'staff:manage'), ('admin', 'settings:manage'), ('admin', 'pos:use'),
  ('manager', 'staff:read'), ('manager', 'pos:use'), ('worker', 'pos:use') on conflict do nothing;

insert into public.dining_tables (name, position_x, position_y) values
  ('Table 1', 10, 10), ('Table 2', 30, 10), ('Table 3', 50, 10), ('Table 4', 70, 10),
  ('Table 5', 20, 40), ('Table 6', 50, 40)
on conflict (name) do nothing;
insert into public.categories (name, sort_order) values
  ('Coffee', 1), ('Drinks', 2), ('Tea & drinks', 3), ('Pastries', 4), ('Food', 5)
on conflict do nothing;
insert into public.products (category_id, name, price, sort_order)
select c.id, v.name, v.price, v.sort_order from (values
  ('Coffee', 'Espresso', 2.50::numeric, 1), ('Coffee', 'Cappuccino', 3.80::numeric, 2),
  ('Coffee', 'Flat white', 4.00::numeric, 3), ('Coffee', 'Latte', 4.20::numeric, 4),
  ('Drinks', 'Coca Cola', 2.50::numeric, 1), ('Drinks', 'Water', 1.50::numeric, 2),
  ('Tea & drinks', 'Fresh orange juice', 4.50::numeric, 1), ('Tea & drinks', 'Iced tea', 3.50::numeric, 2),
  ('Pastries', 'Butter croissant', 2.80::numeric, 1), ('Pastries', 'Pain au chocolat', 3.20::numeric, 2),
  ('Food', 'Avocado toast', 8.50::numeric, 1), ('Food', 'Breakfast sandwich', 7.90::numeric, 2),
  ('Food', 'Burger', 9.50::numeric, 3), ('Food', 'Pizza', 11.00::numeric, 4)
) as v(category_name, name, price, sort_order) join public.categories c on c.name = v.category_name
where not exists (select 1 from public.products p where p.name = v.name);

import { OrderWorkspace } from "@/components/order-workspace";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";

export default async function WorkspacePage() {
  await requireProfile();
  const supabase = await createClient();
  const [{ data: tables }, { data: categories }, { data: products }, { data: openOrders }] = await Promise.all([
    supabase.from("dining_tables").select("id, name, status").order("name"),
    supabase.from("categories").select("id, name").eq("active", true).order("sort_order"),
    supabase.from("products").select("id, category_id, name, price").eq("active", true).order("sort_order"),
    supabase.from("orders").select("id, table_id, status, subtotal").eq("status", "open")
  ]);

  return <OrderWorkspace tables={tables ?? []} categories={categories ?? []} products={products ?? []} openOrders={openOrders ?? []} />;
}

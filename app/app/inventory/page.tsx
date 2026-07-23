import { InventoryManager } from "@/components/inventory-manager";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";
export default async function InventoryPage() { await requireProfile(); const s = await createClient(); const { data: allowed } = await s.rpc("user_has_permission", { required_permission: "inventory:manage" }); if (!allowed) return <section className="mx-auto max-w-xl rounded-lg border bg-card p-8 text-center"><p className="text-sm font-semibold text-primary">ACCESS DENIED</p><h1 className="mt-2 text-2xl font-bold">You cannot manage inventory</h1><p className="mt-3 text-muted-foreground">Ask an administrator to grant inventory:manage.</p></section>;
 const [{ data: products, error: productsError }, { data: movements, error: movementsError }] = await Promise.all([s.from("products").select("id,name,category_id,track_inventory,stock_quantity,low_stock_threshold,allow_negative_stock,categories(name)").order("name"), s.from("product_stock_movements").select("id,product_id,movement_type,quantity_change,stock_before,stock_after,reason,created_at").order("created_at", { ascending: false }).limit(200)]);
 if (productsError || movementsError) return <p className="rounded border border-red-200 bg-red-50 p-5 text-red-800">Inventory could not load. Apply migration <code>20260723090000_simplify_product_inventory.sql</code>.</p>;
 return <InventoryManager products={products ?? []} movements={movements ?? []} />;
}

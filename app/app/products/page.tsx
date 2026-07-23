import { ProductsManager } from "@/components/products-manager";
import { hasPermission } from "@/lib/auth/permissions";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";

export default async function ProductsPage() {
  const profile = await requireProfile();
  if (!hasPermission(profile.role, "products:manage")) return <section className="mx-auto max-w-xl rounded-lg border bg-card p-8 text-center"><p className="text-sm font-semibold text-primary">ACCESS DENIED</p><h1 className="mt-2 text-2xl font-bold">You cannot manage products</h1><p className="mt-3 text-muted-foreground">Ask an administrator to grant you the products:manage permission.</p></section>;
  const supabase = await createClient();
  const [{ data: categoryRows, error: categoryError }, { data: productRows, error: productError }] = await Promise.all([
    supabase.from("categories").select("id, name, description, color, sort_order, active, printer_destination").order("sort_order").order("name"),
    supabase.from("products").select("id, category_id, name, price, tax_rate, cost_price, sku, barcode, printer_destination, track_inventory, active, sort_order").order("sort_order").order("name")
  ]);
  if (categoryError || productError) return <section className="rounded-lg border border-red-200 bg-red-50 p-6"><h1 className="text-2xl font-bold">Products</h1><p className="mt-2 text-red-800">We could not load the catalog. Please refresh the page or verify your database permissions.</p></section>;
  const products = (productRows ?? []).map(product => ({ ...product, price: Number(product.price), tax_rate: Number(product.tax_rate), cost_price: Number(product.cost_price), printer_destination: product.printer_destination as "internal" | "none" }));
  const categories = (categoryRows ?? []).map(category => ({ ...category, printer_destination: category.printer_destination as "internal" | "none", product_count: products.filter(product => product.category_id === category.id).length }));
  return <ProductsManager categories={categories} products={products} />;
}

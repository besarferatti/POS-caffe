import { OrderWorkspace } from "@/components/order-workspace";
import { requireProfile } from "@/lib/auth/user";
import { objectsFromFloorLayout, tablesFromFloorLayout, type TableStatus } from "@/lib/floor-tables";
import { createClient } from "@/lib/supabase/server";

export default async function OrdersPage() {
  await requireProfile();
  const supabase = await createClient();
  const [{ data: floorLayout, error: floorLayoutError }, { data: categories, error: categoriesError }, { data: products, error: productsError }, { data: openOrders, error: openOrdersError }, { data: reservations }] = await Promise.all([
    supabase.from("floor_layouts").select("layout").eq("id", 1).maybeSingle(),
    supabase.from("categories").select("id, name").eq("active", true).order("sort_order"),
    supabase.from("products").select("id, category_id, name, price").eq("active", true).order("sort_order"),
    supabase.from("orders").select("id, table_id, status, subtotal").in("status", ["open", "sent", "partially_paid", "internal_only"]),
    supabase.from("table_reservations").select("table_object_id").is("released_at", null)
  ]);
  const openTableIds = new Set((openOrders ?? []).map((order) => order.table_id));
  const reservedTableIds = new Set((reservations ?? []).map((reservation) => reservation.table_object_id));
  const tables = floorLayout ? tablesFromFloorLayout(floorLayout.layout).map((table) => ({ ...table, status: (openTableIds.has(table.id) ? "occupied" : reservedTableIds.has(table.id) ? "reserved" : "available") as TableStatus })) : [];
  const catalogError = categoriesError || productsError
    ? "The menu could not be loaded. Please refresh the page and try again."
    : undefined;

  return <OrderWorkspace tables={tables} objects={floorLayout ? objectsFromFloorLayout(floorLayout.layout) : []} floorError={floorLayoutError ? "The saved floor layout could not be loaded. Please verify your access and try again." : !floorLayout ? "No saved floor layout was found. Save the floor plan before opening orders." : undefined} catalogError={catalogError} categories={categories ?? []} products={products ?? []} openOrders={openOrders ?? []} openOrdersError={openOrdersError ? "Open-order statuses could not be loaded. Table availability may be out of date." : undefined} />;
}

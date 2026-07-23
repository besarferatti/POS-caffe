import { OrderWorkspace } from "@/components/order-workspace";
import { requireProfile } from "@/lib/auth/user";
import { tablesFromFloorLayout, type TableStatus } from "@/lib/floor-tables";
import { createClient } from "@/lib/supabase/server";

export default async function WorkspacePage() {
  await requireProfile();
  const supabase = await createClient();
  const [{ data: floorLayout, error: floorLayoutError }, { data: categories }, { data: products }, { data: openOrders }] = await Promise.all([
    supabase.from("floor_layouts").select("layout").eq("id", 1).maybeSingle(),
    supabase.from("categories").select("id, name").eq("active", true).order("sort_order"),
    supabase.from("products").select("id, category_id, name, price").eq("active", true).order("sort_order"),
    supabase.from("orders").select("id, table_id, status, subtotal").eq("status", "open")
  ]);

  const openTableIds = new Set((openOrders ?? []).map((order) => order.table_id));
  const tables = floorLayout
    ? tablesFromFloorLayout(floorLayout.layout).map((table) => ({
      ...table,
      // An open order is authoritative for occupancy; layout-provided reserved
      // and available states otherwise remain untouched.
      status: (openTableIds.has(table.id) ? "occupied" : table.status) as TableStatus
    }))
    : [];
  const floorError = floorLayoutError
    ? "The saved floor layout could not be loaded. Please verify your access and try again."
    : !floorLayout
      ? "No saved floor layout was found. Save the floor plan before opening orders."
      : undefined;

  return <OrderWorkspace tables={tables} floorError={floorError} categories={categories ?? []} products={products ?? []} openOrders={openOrders ?? []} />;
}

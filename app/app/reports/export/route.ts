import { NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

const esc = (x: unknown) => `"${String(x ?? "").replaceAll('"', '""')}"`;
const orderColumns = ["id", "short_id", "receipt_number", "table", "worker", "opened_at", "closed_at", "status", "total", "paid", "balance"];

export async function GET(request: NextRequest) {
  const s = await createClient();
  const ok = Boolean((await s.rpc("user_has_permission", { required_permission: "reports:financial" })).data);
  if (!ok) return new Response("Access denied", { status: 403 });
  const q = request.nextUrl.searchParams, start = q.get("start") || new Date().toISOString().slice(0, 10), end = q.get("end") || start;
  const { data, error } = await s.rpc("reporting_dashboard", { p_range_start: `${start}T00:00:00Z`, p_range_end: `${end}T00:00:00Z`, p_staff_id: q.get("staff") || null, p_method_id: q.get("method") || null, p_category_id: q.get("category") || null });
  if (error) return new Response(error.message, { status: 400 });
  const kind = q.get("kind") || "orders";
  const rows = kind === "orders" ? data.orders : kind === "products" ? data.products : kind === "categories" ? data.categories : kind === "payments" ? data.payment_methods : kind === "employees" ? data.employees : kind === "taxes" ? [{ taxes: data.summary?.taxes ?? 0, discounts: data.summary?.discounts ?? 0 }] : kind === "internal-only" ? data.orders.filter((row: Record<string, unknown>) => row.status === "internal_only") : [];
  const keys = kind === "orders" ? orderColumns : rows.length ? Object.keys(rows[0]) : [];
  const csv = [keys.map(esc).join(","), ...rows.map((r: Record<string, unknown>) => keys.map(k => esc(r[k])).join(","))].join("\n");
  return new Response(csv, { headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="${kind}-report.csv"` } });
}

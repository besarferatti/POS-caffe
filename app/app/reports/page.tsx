import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";
import { ReportsClient } from "@/components/reports-client";

export default async function ReportsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requireProfile(); const supabase = await createClient(); const params = await searchParams;
  const get = (key: string) => typeof params[key] === "string" ? params[key] as string : undefined;
  const operational = Boolean((await supabase.rpc("user_has_permission", { required_permission: "reports:operational" })).data);
  const financial = Boolean((await supabase.rpc("user_has_permission", { required_permission: "reports:financial" })).data);
  if (!operational && !financial) return <section className="mx-auto max-w-lg rounded-lg border bg-card p-8 text-center"><h1 className="text-2xl font-bold">Access denied</h1><p className="mt-2 text-muted-foreground">You do not have permission to view reports. Ask an administrator to grant a reports permission.</p></section>;
  const today = new Date().toISOString().slice(0, 10); const start = get("start") ?? today; const end = get("end") ?? today;
  const startAt = `${start}T00:00:00.000Z`; const endAt = `${end}T00:00:00.000Z`;
  const { data, error } = await supabase.rpc("reporting_dashboard", { p_range_start: startAt, p_range_end: endAt, p_staff_id: get("staff") || null, p_method_id: get("method") || null, p_category_id: get("category") || null });
  const [staff, methods, categories] = await Promise.all([supabase.from("profiles").select("id,display_name").order("display_name"), supabase.from("payment_methods").select("id,name").eq("enabled",true).order("sort_order"), supabase.from("categories").select("id,name").order("name")]);
  return <ReportsClient data={data ?? null} error={error?.message} canOperational={operational} canFinancial={financial} filters={{start,end,staff:get("staff") ?? "",method:get("method") ?? "",category:get("category") ?? ""}} staff={(staff.data ?? []).map((item) => ({ id: item.id, name: item.display_name }))} methods={methods.data ?? []} categories={categories.data ?? []} />;
}

import { StaffManager, type StaffRecord } from "@/app/app/staff/staff-manager";
import { requireProfile } from "@/lib/auth/user";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

export default async function StaffPage() {
  const profile = await requireProfile(); const client = await createClient();
  const { data: allowed } = await client.rpc("user_has_permission", { required_permission: "staff:manage" });
  if (!allowed) return <section className="rounded-lg border border-destructive/30 bg-destructive/5 p-8"><p className="text-sm font-medium text-destructive">ACCESS DENIED</p><h1 className="mt-2 text-3xl font-bold">Staff management is restricted</h1><p className="mt-3 text-muted-foreground">Your account does not have the staff:manage permission.</p></section>;
  const admin = createAdminClient();
  const [{ data: profiles, error }, { data: permissions }, { data: overrides }, users] = await Promise.all([
    admin.from("profiles").select("id, display_name, role, active, created_at, updated_at, pin_hash").order("created_at", { ascending: false }),
    admin.from("permissions").select("key, description").order("key"), admin.from("user_permissions").select("user_id, permission_key, granted"), admin.auth.admin.listUsers({ perPage: 1000 })
  ]);
  if (error) return <section role="alert" className="rounded-lg border border-destructive/30 p-8"><h1 className="text-2xl font-bold">Unable to load staff</h1><p className="mt-2 text-muted-foreground">{error.message}</p></section>;
  const emailById = new Map(users.data.users.map((user) => [user.id, user.email ?? ""]));
  const staff: StaffRecord[] = (profiles ?? []).map((item) => ({ ...item, email: emailById.get(item.id) ?? "", pin_configured: Boolean(item.pin_hash), overrides: (overrides ?? []).filter((o) => o.user_id === item.id).map((o) => ({ key: o.permission_key, granted: o.granted })) }));
  return <StaffManager staff={staff} permissions={permissions ?? []} currentUserId={profile.id} />;
}

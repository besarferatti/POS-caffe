"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";

import { requireProfile } from "@/lib/auth/user";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

const role = z.enum(["admin", "manager", "worker"]);
const staffSchema = z.object({ id: z.string().uuid().optional(), fullName: z.string().trim().min(1, "Full name is required.").max(120), email: z.string().trim().email("Enter a valid email."), password: z.string().min(10, "Temporary password must be at least 10 characters.").optional(), role, active: z.boolean(), pin: z.string().regex(/^\d{4,12}$/, "PIN must contain 4–12 digits.").optional().or(z.literal("")), permissions: z.array(z.object({ key: z.string(), granted: z.boolean() })) });

async function authorize() {
  const profile = await requireProfile();
  const client = await createClient();
  const { data, error } = await client.rpc("user_has_permission", { required_permission: "staff:manage" });
  if (error || !data) throw new Error("You do not have permission to manage staff.");
  return { actor: profile, admin: createAdminClient() };
}
async function audit(admin: ReturnType<typeof createAdminClient>, actorId: string, targetId: string, action: string, before_data: unknown, after_data: unknown, reason?: string) {
  await admin.from("staff_audit_log").insert({ actor_id: actorId, target_user_id: targetId, action, before_data, after_data, reason: reason || null });
}
function message(error: { message: string; code?: string }) { return error.code === "23505" ? "An account with that email already exists." : error.message || "The change could not be saved."; }

export async function saveStaff(input: unknown) {
  const parsed = staffSchema.safeParse(input); if (!parsed.success) return { error: parsed.error.issues[0].message };
  const { actor, admin } = await authorize(); const value = parsed.data;
  if (!value.id && !value.password) return { error: "A temporary password is required for a new account." };
  if (!value.id) {
    const { data, error } = await admin.auth.admin.createUser({ email: value.email, password: value.password!, email_confirm: true, user_metadata: { display_name: value.fullName } });
    if (error || !data.user) return { error: message(error ?? { message: "Unable to create account." }) };
    const pin_hash = value.pin ? await hashPin(value.pin) : null;
    const { error: profileError } = await admin.from("profiles").update({ display_name: value.fullName, role: value.role, active: value.active, pin_hash, must_change_password: true }).eq("id", data.user.id);
    if (profileError) { await admin.auth.admin.deleteUser(data.user.id); return { error: message(profileError) }; }
    await saveOverrides(admin, data.user.id, value.permissions); await audit(admin, actor.id, data.user.id, "staff_created", null, { full_name: value.fullName, role: value.role, active: value.active });
    if (value.pin) await audit(admin, actor.id, data.user.id, "pin_set", null, { pin_configured: true });
  } else {
    const { data: before, error: readError } = await admin.from("profiles").select("display_name, role, active, pin_hash").eq("id", value.id).single();
    if (readError) return { error: message(readError) };
    if (value.id === actor.id && !value.active) return { error: "You cannot deactivate your own active account." };
    const update: Record<string, unknown> = { display_name: value.fullName, role: value.role, active: value.active };
    if (value.pin) update.pin_hash = await hashPin(value.pin);
    const { error } = await admin.from("profiles").update(update).eq("id", value.id); if (error) return { error: message(error) };
    await saveOverrides(admin, value.id, value.permissions);
    if (before.display_name !== value.fullName || before.role !== value.role) await audit(admin, actor.id, value.id, "role_changed", before, { full_name: value.fullName, role: value.role });
    if (before.active !== value.active) await audit(admin, actor.id, value.id, value.active ? "staff_activated" : "staff_deactivated", { active: before.active }, { active: value.active });
    if (value.pin) await audit(admin, actor.id, value.id, "pin_set", { pin_configured: Boolean(before.pin_hash) }, { pin_configured: true });
    await audit(admin, actor.id, value.id, "permissions_changed", null, { overrides: value.permissions });
  }
  revalidatePath("/app/staff"); return { success: "Staff account saved." };
}
async function hashPin(pin: string) { const admin = createAdminClient(); const { data, error } = await admin.rpc("hash_staff_pin", { candidate: pin }); if (error || !data) throw new Error("Could not secure the PIN."); return data as string; }
async function saveOverrides(admin: ReturnType<typeof createAdminClient>, userId: string, permissions: { key: string; granted: boolean }[]) { if (!permissions.length) return; await admin.from("user_permissions").upsert(permissions.map((permission) => ({ user_id: userId, permission_key: permission.key, granted: permission.granted })), { onConflict: "user_id,permission_key" }); }
export async function setTemporaryPassword(id: string, password: string) { const valid = z.string().uuid().safeParse(id); const pass = z.string().min(10, "Temporary password must be at least 10 characters.").safeParse(password); if (!valid.success || !pass.success) return { error: pass.success ? "Invalid staff member." : pass.error.issues[0].message }; const { actor, admin } = await authorize(); const { error } = await admin.auth.admin.updateUserById(id, { password: pass.data }); if (error) return { error: message(error) }; await admin.from("profiles").update({ must_change_password: true }).eq("id", id); await audit(admin, actor.id, id, "temporary_password_set", null, { must_change_password: true }); return { success: "Temporary password set." }; }
export async function sendPasswordReset(id: string) { const { actor, admin } = await authorize(); const { data: user } = await admin.auth.admin.getUserById(id); if (!user.user?.email) return { error: "Staff account not found." }; const { error } = await admin.auth.resetPasswordForEmail(user.user.email, { redirectTo: `${process.env.NEXT_PUBLIC_SITE_URL ?? ""}/login` }); if (error) return { error: message(error) }; await audit(admin, actor.id, id, "password_reset_requested", null, { email: user.user.email }); return { success: "Password reset email sent." }; }

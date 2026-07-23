import { redirect } from "next/navigation";

import { roles, type Role } from "@/lib/auth/permissions";
import { createClient } from "@/lib/supabase/server";

export async function getCurrentProfile() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: profile } = await supabase
    .from("profiles")
    .select("id, display_name, role, active")
    .eq("id", user.id)
    .single();

  if (!profile || !profile.active || !roles.includes(profile.role as Role)) return null;
  return { ...profile, role: profile.role as Role, email: user.email ?? "" };
}

export async function requireProfile() {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/login");
  return profile;
}

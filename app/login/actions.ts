"use server";

import { redirect } from "next/navigation";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";

const credentialsSchema = z.object({ email: z.string().email(), password: z.string().min(8) });

export async function signIn(formData: FormData) {
  const parsed = credentialsSchema.safeParse({ email: formData.get("email"), password: formData.get("password") });
  if (!parsed.success) redirect("/login?error=Enter+a+valid+email+and+password");

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  if (error) redirect("/login?error=Unable+to+sign+in");
  const { data: profile } = await supabase.from("profiles").select("active").eq("id", (await supabase.auth.getUser()).data.user?.id ?? "").maybeSingle();
  if (!profile?.active) { await supabase.auth.signOut(); redirect("/login?error=This+staff+account+is+inactive"); }
  redirect("/app");
}

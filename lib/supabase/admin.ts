import { createClient } from "@supabase/supabase-js";

import { env } from "@/lib/env";

/** Server-only Supabase client. Never import this from a client component. */
export function createAdminClient() {
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required for staff administration.");
  return createClient(env.NEXT_PUBLIC_SUPABASE_URL, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });
}

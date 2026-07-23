import { redirect } from "next/navigation";

import { hasPermission } from "@/lib/auth/permissions";
import { requireProfile } from "@/lib/auth/user";

export default async function StaffPage() {
  const profile = await requireProfile();
  if (!hasPermission(profile.role, "staff:read")) redirect("/app");
  return <section><p className="text-sm font-medium text-primary">ACCESS CONTROL</p><h1 className="mt-2 text-3xl font-bold tracking-tight">Staff</h1><p className="mt-3 max-w-2xl text-muted-foreground">Staff management will be added in a future phase. This protected route demonstrates manager and administrator access.</p></section>;
}

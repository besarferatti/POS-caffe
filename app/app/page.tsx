import { ShieldCheck } from "lucide-react";

import { requireProfile } from "@/lib/auth/user";

export default async function WorkspacePage() {
  const profile = await requireProfile();
  return <section className="max-w-3xl"><p className="text-sm font-medium text-primary">PHASE 1</p><h1 className="mt-2 text-3xl font-bold tracking-tight">Your workspace is ready</h1><p className="mt-3 text-muted-foreground">Welcome, {profile.display_name}. Authentication and role-based access are configured for this point-of-sale foundation.</p><div className="mt-8 flex gap-3 rounded-lg border bg-card p-5"><ShieldCheck className="mt-0.5 size-5 text-primary" /><div><h2 className="font-semibold capitalize">{profile.role} access</h2><p className="mt-1 text-sm text-muted-foreground">Your permissions are enforced in the application and database.</p></div></div></section>;
}

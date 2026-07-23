import Link from "next/link";
import type { ReactNode } from "react";
import { LogOut, ShieldCheck } from "lucide-react";

import { Button } from "@/components/ui/button";
import { hasPermission } from "@/lib/auth/permissions";
import { createClient } from "@/lib/supabase/server";
import { requireProfile } from "@/lib/auth/user";
import { signOut } from "./actions";

export default async function AppLayout({ children }: Readonly<{ children: ReactNode }>) {
  const profile = await requireProfile();
  const { data: staffAccess } = await (await createClient()).rpc("user_has_permission", { required_permission: "staff:manage" });
  const canManageStaff = Boolean(staffAccess);
  const canManageProducts = hasPermission(profile.role, "products:manage");
  const { data: inventoryAccess } = await (await createClient()).rpc("user_has_permission", { required_permission: "inventory:manage" });
  const canManageInventory = Boolean(inventoryAccess);
  const [operationalReports, financialReports] = await Promise.all([
    (await createClient()).rpc("user_has_permission", { required_permission: "reports:operational" }),
    (await createClient()).rpc("user_has_permission", { required_permission: "reports:financial" })
  ]);
  const canViewReports = Boolean(operationalReports.data || financialReports.data);

  return (
    <div className="min-h-screen md:grid md:grid-cols-[16rem_1fr]">
      <aside className="border-b bg-card p-5 md:min-h-screen md:border-b-0 md:border-r">
        <Link href="/app/orders" className="text-lg font-bold tracking-tight text-primary">POS CAFFÈ</Link>
        <nav className="mt-8 space-y-1"><Link className="block rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground" href="/app/orders">Orders</Link><Link className="block rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground" href="/app/floor-plan">Floor Plan</Link>{canManageProducts && <Link className="block rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground" href="/app/products">Products</Link>}{canManageInventory && <Link className="block rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground" href="/app/inventory">Inventory</Link>}{canViewReports && <Link className="block rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground" href="/app/reports">Reports</Link>}{canManageStaff && <Link className="block rounded-md px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-accent hover:text-foreground" href="/app/staff">Staff</Link>}</nav>
        <div className="mt-8 border-t pt-4"><p className="truncate text-sm font-medium">{profile.display_name}</p><p className="flex items-center gap-1 text-xs capitalize text-muted-foreground"><ShieldCheck className="size-3" />{profile.role}</p><form action={signOut} className="mt-4"><Button type="submit" variant="ghost" size="sm" className="w-full justify-start gap-2"><LogOut className="size-4" />Sign out</Button></form></div>
      </aside>
      <main className="p-6 md:p-10">{children}</main>
    </div>
  );
}

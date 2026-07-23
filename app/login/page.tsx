import Link from "next/link";

import { Button } from "@/components/ui/button";
import { signIn } from "./actions";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <main className="grid min-h-screen place-items-center p-6">
      <form action={signIn} className="w-full max-w-sm space-y-6 rounded-lg border bg-card p-8 shadow-sm">
        <div><p className="text-sm font-medium text-primary">POS CAFFÈ</p><h1 className="mt-1 text-2xl font-semibold">Welcome back</h1><p className="mt-2 text-sm text-muted-foreground">Sign in to access your workspace.</p></div>
        {error && <p role="alert" className="rounded-md bg-destructive/10 p-3 text-sm text-destructive">{error}</p>}
        <label className="block text-sm font-medium">Email<input name="email" type="email" autoComplete="email" required className="mt-1 block h-10 w-full rounded-md border bg-background px-3" /></label>
        <label className="block text-sm font-medium">Password<input name="password" type="password" autoComplete="current-password" required minLength={8} className="mt-1 block h-10 w-full rounded-md border bg-background px-3" /></label>
        <Button className="w-full" type="submit">Sign in</Button>
        <p className="text-center text-xs text-muted-foreground">Accounts are created by an administrator. <Link className="underline" href="/">Return home</Link></p>
      </form>
    </main>
  );
}

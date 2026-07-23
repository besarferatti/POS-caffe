import { signIn } from "./actions";
import { LoginForm } from "./login-form";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <main className="grid min-h-screen place-items-center p-6">
      <LoginForm error={error} signIn={signIn} />
    </main>
  );
}

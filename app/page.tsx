import { redirect } from "next/navigation";

import { getCurrentProfile } from "@/lib/auth/user";

export default async function HomePage() {
  const profile = await getCurrentProfile();
  redirect(profile ? "/app" : "/login");
}

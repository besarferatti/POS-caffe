import { FloorPlanEditor } from "@/components/floor-plan-editor";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";

export default async function FloorPlanPage() {
  await requireProfile();
  const { data } = await (await createClient()).from("floor_layouts").select("layout").eq("id", 1).maybeSingle();
  return <FloorPlanEditor initialLayout={data?.layout ?? { objects: [] }} />;
}

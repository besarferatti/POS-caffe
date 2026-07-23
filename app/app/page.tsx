import { FloorPlanEditor, type FloorLayout } from "./floor-plan-editor";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";

const emptyLayout: FloorLayout = { objects: [], viewport: { x: 0, y: 0, scale: 1 } };

export default async function WorkspacePage() {
  const profile = await requireProfile();
  const supabase = await createClient();
  const { data } = await supabase.from("floor_layouts").select("layout").eq("id", 1).maybeSingle();
  const layout = (data?.layout ?? emptyLayout) as FloorLayout;
  return <FloorPlanEditor initialLayout={layout} isAdmin={profile.role === "admin"} />;
}

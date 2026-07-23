"use server";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";
async function db() { await requireProfile(); const s = await createClient(); const { data } = await s.rpc("user_has_permission", { required_permission: "inventory:manage" }); if (!data) throw new Error("You do not have permission to manage inventory."); return s; }
const id = z.string().uuid();
const message = (error: { message: string }) => error.message;
const done = () => { revalidatePath("/app/inventory"); revalidatePath("/app/orders"); return { success: "Inventory updated." }; };
export async function setTracking(productId: string, trackInventory: boolean) { try { id.parse(productId); const { error } = await (await db()).from("products").update({ track_inventory: trackInventory }).eq("id", productId); return error ? { error: message(error) } : done(); } catch (e) { return { error: e instanceof Error ? e.message : "Unable to update inventory." }; } }
export async function setThreshold(productId: string, threshold: unknown) { try { id.parse(productId); const value = z.coerce.number().min(0).parse(threshold); const { error } = await (await db()).from("products").update({ low_stock_threshold: value }).eq("id", productId); return error ? { error: message(error) } : done(); } catch (e) { return { error: e instanceof Error ? e.message : "Unable to update threshold." }; } }
export async function adjustProductStock(productId: string, type: unknown, quantity: unknown, reason: unknown) { try { id.parse(productId); const adjustment = z.enum(["add", "remove", "set"]).parse(type); const amount = z.coerce.number().min(0).parse(quantity); const why = z.string().trim().min(1, "A reason is required.").parse(reason); const { error } = await (await db()).rpc("adjust_product_stock", { p_product_id: productId, p_adjustment_type: adjustment, p_quantity: amount, p_reason: why }); return error ? { error: message(error) } : done(); } catch (e) { return { error: e instanceof Error ? e.message : "Unable to adjust stock." }; } }

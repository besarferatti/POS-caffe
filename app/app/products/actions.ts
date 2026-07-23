"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";

import { hasPermission } from "@/lib/auth/permissions";
import { requireProfile } from "@/lib/auth/user";
import { createClient } from "@/lib/supabase/server";

const text = (max: number) => z.string().trim().max(max);
const categorySchema = z.object({ id: z.string().uuid().optional(), name: text(100).min(1, "A category name is required."), description: text(1000), color: z.string().trim().max(32).nullable(), sort_order: z.coerce.number().int("Sort order must be a whole number."), active: z.boolean(), printer_destination: z.enum(["internal", "none"]) });
const productSchema = z.object({ id: z.string().uuid().optional(), category_id: z.string().uuid("Select a category."), name: text(160).min(1, "A product name is required."), price: z.coerce.number().min(0, "Selling price cannot be negative."), tax_rate: z.coerce.number().min(0).max(100, "Tax rate must be between 0 and 100."), cost_price: z.coerce.number().min(0, "Cost price cannot be negative."), sku: z.string().trim().max(100).nullable(), barcode: z.string().trim().max(100).nullable(), printer_destination: z.enum(["internal", "none"]), track_inventory: z.boolean(), active: z.boolean(), sort_order: z.coerce.number().int("Sort order must be a whole number.") });

async function authorize() { const profile = await requireProfile(); if (!hasPermission(profile.role, "products:manage")) throw new Error("You do not have permission to manage products."); return createClient(); }
function databaseMessage(error: { code?: string; message: string }) { if (error.code === "23505") return "That value is already in use. Category names, SKUs, and barcodes must be unique."; return error.message || "We could not save your changes. Please try again."; }

export async function saveCategory(input: unknown) {
  const parsed = categorySchema.safeParse(input); if (!parsed.success) return { error: parsed.error.issues[0].message };
  const supabase = await authorize(); const { id, ...values } = parsed.data;
  const { error } = id ? await supabase.from("categories").update(values).eq("id", id) : await supabase.from("categories").insert(values);
  if (error) return { error: databaseMessage(error) }; revalidatePath("/app/products"); revalidatePath("/app/orders"); return { success: "Category saved." };
}
export async function saveProduct(input: unknown) {
  const parsed = productSchema.safeParse(input); if (!parsed.success) return { error: parsed.error.issues[0].message };
  const supabase = await authorize(); const { id, ...raw } = parsed.data; const values = { ...raw, sku: raw.sku || null, barcode: raw.barcode || null };
  const { error } = id ? await supabase.from("products").update(values).eq("id", id) : await supabase.from("products").insert(values);
  if (error) return { error: databaseMessage(error) }; revalidatePath("/app/products"); revalidatePath("/app/orders"); return { success: "Product saved." };
}
export async function setCategoryActive(id: string, active: boolean) { const supabase = await authorize(); const { error } = await supabase.from("categories").update({ active }).eq("id", id); if (error) return { error: databaseMessage(error) }; revalidatePath("/app/products"); revalidatePath("/app/orders"); return { success: `Category ${active ? "activated" : "deactivated"}.` }; }
export async function setProductActive(id: string, active: boolean) { const supabase = await authorize(); const { error } = await supabase.from("products").update({ active }).eq("id", id); if (error) return { error: databaseMessage(error) }; revalidatePath("/app/products"); revalidatePath("/app/orders"); return { success: `Product ${active ? "activated" : "deactivated"}.` }; }
export async function setCategorySort(id: string, sort_order: number) { const supabase = await authorize(); const { error } = await supabase.from("categories").update({ sort_order }).eq("id", id); if (error) return { error: databaseMessage(error) }; revalidatePath("/app/products"); revalidatePath("/app/orders"); return { success: "Category order updated." }; }

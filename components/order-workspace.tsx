"use client";

import { Minus, Plus, ReceiptText, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";

import { Button } from "@/components/ui/button";
import { createClient } from "@/lib/supabase/client";

type Table = { id: string; name: string; status: "available" | "occupied" | "reserved"; x?: number; y?: number; width?: number; height?: number; rotation?: number; zIndex?: number; shape?: "round" | "square" | "rectangle" };
type FloorObject = { id: string; type: string; label: string; x: number; y: number; width: number; height: number; rotation: number; zIndex: number; shape?: "round" | "square" | "rectangle"; isTable: boolean };
type Category = { id: string; name: string };
type Product = { id: string; category_id: string; name: string; price: number };
type Order = { id: string; table_id: string; status: string; subtotal: number; total?: number };
type OrderItem = { id: string; product_id: string; quantity: number; price: number; notes: string; product?: { name: string }[] | null };

const money = (amount: number) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(amount);

export function OrderWorkspace({ tables: initialTables, objects, floorError, catalogError, categories, products, openOrders, openOrdersError }: { tables: Table[]; objects: FloorObject[]; floorError?: string; catalogError?: string; categories: Category[]; products: Product[]; openOrders: Order[]; openOrdersError?: string }) {
  const [tables, setTables] = useState(initialTables);
  const [selectedTable, setSelectedTable] = useState<Table | null>(null);
  const [, setOrders] = useState(openOrders);
  const [activeOrder, setActiveOrder] = useState<Order | null>(null);
  const [items, setItems] = useState<OrderItem[]>([]);
  const [categoryId, setCategoryId] = useState(categories[0]?.id ?? "");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const visibleProducts = useMemo(() => products.filter((product) => product.category_id === categoryId), [products, categoryId]);
  const subtotal = useMemo(() => items.reduce((sum, item) => sum + Number(item.price) * item.quantity, 0), [items]);
  const activeCategory = categories.find((category) => category.id === categoryId);

  async function selectTable(table: Table) {
    setBusy(true); setMessage(""); setSelectedTable(table); setActiveOrder(null); setItems([]);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("open_order_for_table", { target_table_id: table.id }).single();
    if (error || !data) { setMessage("Unable to open this table. Please try again."); setBusy(false); return; }
    const order = data as Order;
    setActiveOrder(order); setOrders((current) => current.some((entry) => entry.id === order.id) ? current : [...current, order]);
    setTables((current) => current.map((entry) => entry.id === table.id ? { ...entry, status: "occupied" } : entry));
    setSelectedTable((current) => current ? { ...current, status: "occupied" } : current);
    const { data: orderItems, error: itemsError } = await supabase.from("order_items").select("id, product_id, quantity, price, notes, product:products(name)").eq("order_id", order.id).is("deleted_at", null).order("created_at");
    if (itemsError) setMessage("Order opened, but its items could not be loaded.");
    setItems((orderItems as OrderItem[]) ?? []); setBusy(false);
  }

  async function addProduct(product: Product) {
    if (!activeOrder || busy) return;
    setBusy(true); const supabase = createClient();
    const existing = items.find((item) => item.product_id === product.id);
    const result = existing
      ? await supabase.from("order_items").update({ quantity: existing.quantity + 1 }).eq("id", existing.id)
      : await supabase.from("order_items").insert({ order_id: activeOrder.id, product_id: product.id, quantity: 1, price: product.price }).select("id, product_id, quantity, price, notes, product:products(name)").single();
    if (result.error) setMessage("Could not add item. Please try again.");
    else setItems((current) => existing
      ? current.map((item) => item.id === existing.id ? { ...item, quantity: item.quantity + 1 } : item)
      : [...current, result.data as OrderItem]);
    setBusy(false);
  }

  async function changeQuantity(item: OrderItem, nextQuantity: number) {
    setBusy(true); const supabase = createClient();
    const { data: { user } } = await supabase.auth.getUser();
    const result = nextQuantity <= 0
      ? await supabase.from("order_items").update({ deleted_at: new Date().toISOString(), deleted_by: user?.id }).eq("id", item.id)
      : await supabase.from("order_items").update({ quantity: nextQuantity }).eq("id", item.id);
    if (result.error) setMessage("Could not update item. Please try again.");
    else setItems((current) => nextQuantity <= 0 ? current.filter((entry) => entry.id !== item.id) : current.map((entry) => entry.id === item.id ? { ...entry, quantity: nextQuantity } : entry));
    setBusy(false);
  }

  async function saveNotes(item: OrderItem, notes: string) {
    if (busy || notes === item.notes) return;
    setBusy(true); setMessage("");
    const { error } = await createClient().from("order_items").update({ notes }).eq("id", item.id);
    if (error) setMessage("Could not save item notes. Please try again.");
    else setItems((current) => current.map((entry) => entry.id === item.id ? { ...entry, notes } : entry));
    setBusy(false);
  }

  async function saveOrder() {
    if (!activeOrder) return;
    setBusy(true); const { error } = await createClient().from("orders").update({ subtotal, total: subtotal }).eq("id", activeOrder.id);
    setMessage(error ? "Could not save the order." : "Order saved."); setBusy(false);
  }

  return <section className="mx-auto max-w-7xl"><div className="mb-7 flex items-end justify-between"><div><p className="text-sm font-semibold text-primary">ORDER MANAGEMENT</p><h1 className="mt-1 text-3xl font-bold tracking-tight">Tables & orders</h1></div><p className="hidden text-sm text-muted-foreground sm:block">Tap a table to start or resume an order</p></div>
    <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_27rem]"><div className="space-y-6"><div className="rounded-xl border bg-card p-4 shadow-sm"><div className="mb-4 flex items-center justify-between"><h2 className="font-semibold">Floor</h2><div className="flex gap-3 text-xs text-muted-foreground"><span>● Available</span><span className="text-amber-600">● Occupied</span><span className="text-blue-600">● Reserved</span></div></div>{floorError ? <p role="alert" className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">{floorError}</p> : tables.length === 0 ? <p className="rounded-md bg-muted p-3 text-sm text-muted-foreground">This floor layout has no table objects.</p> : <div className="floor-canvas" aria-label="Read-only floor plan">{objects.map((object) => { const table = tables.find((entry) => entry.id === object.id); const status = table?.status; const isRound = object.shape === "round"; return object.isTable && table ? <button key={object.id} onClick={() => selectTable(table)} disabled={busy} title={`${table.name} — ${status}`} className={`floor-object floor-table ${isRound ? "rounded-full" : "rounded-md"} ${status === "occupied" ? "floor-occupied" : status === "reserved" ? "floor-reserved" : ""} ${selectedTable?.id === object.id ? "floor-selected" : ""}`} style={{ left: object.x, top: object.y, width: object.width, height: object.height, transform: `rotate(${object.rotation}deg)`, zIndex: object.zIndex }}><span>{table.name}</span><small>{status}</small></button> : <div key={object.id} className={`floor-object floor-decoration floor-${object.type}`} style={{ left: object.x, top: object.y, width: object.width, height: object.height, transform: `rotate(${object.rotation}deg)`, zIndex: object.zIndex }}>{object.label && <span>{object.label}</span>}</div>; })}</div>}</div>
      {activeOrder && <div className="rounded-xl border bg-card p-4 shadow-sm"><div className="flex items-center justify-between"><h2 className="font-semibold">Menu</h2><span className="text-sm text-muted-foreground">{selectedTable?.name}</span></div>{catalogError ? <p role="alert" className="mt-4 rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">{catalogError}</p> : categories.length === 0 ? <p className="mt-4 rounded-md bg-muted p-3 text-sm text-muted-foreground">No active categories are available.</p> : <><div className="mt-4 flex gap-2 overflow-x-auto pb-1">{categories.map((category) => <button key={category.id} onClick={() => setCategoryId(category.id)} className={`shrink-0 rounded-full px-4 py-2 text-sm font-medium ${categoryId === category.id ? "bg-primary text-primary-foreground" : "bg-muted hover:bg-accent"}`}>{category.name}</button>)}</div><div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3">{visibleProducts.length === 0 ? <p className="col-span-full rounded-md bg-muted p-3 text-sm text-muted-foreground">No active products in {activeCategory?.name ?? "this category"}.</p> : visibleProducts.map((product) => <button key={product.id} onClick={() => addProduct(product)} disabled={busy} className="min-h-28 rounded-xl border bg-background p-4 text-left transition hover:border-primary/40 active:scale-[.98]"><span className="block font-semibold">{product.name}</span><span className="mt-1 block text-xs text-muted-foreground">{activeCategory?.name}</span><span className="mt-3 block text-primary">{money(Number(product.price))}</span></button>)}</div></>}</div>}</div>
      <aside className="h-fit rounded-xl border bg-card shadow-sm xl:sticky xl:top-6"><div className="border-b p-5"><div className="flex items-center gap-2"><ReceiptText className="size-5 text-primary" /><h2 className="font-semibold">{selectedTable ? `${selectedTable.name} order` : "Select a table"}</h2></div>{activeOrder && <p className="mt-1 text-xs text-muted-foreground">Open order · {activeOrder.id.slice(0, 8)}</p>}</div><div className="min-h-56 p-3">{openOrdersError && <p role="alert" className="mb-3 rounded-md border border-amber-500/30 bg-amber-500/5 p-3 text-sm text-amber-700">{openOrdersError}</p>}{!activeOrder ? <p className="p-3 text-sm text-muted-foreground">Choose a table to create a new order or reopen its active order.</p> : items.length === 0 ? <p className="p-3 text-sm text-muted-foreground">Add products from the menu to begin.</p> : items.map((item) => <div key={item.id} className="border-b py-3 last:border-0"><div className="flex items-center gap-2"><div className="min-w-0 flex-1"><p className="truncate text-sm font-medium">{item.product?.[0]?.name}</p><p className="text-xs text-muted-foreground">{money(Number(item.price))} each</p></div><div className="flex items-center rounded-md bg-muted"><button aria-label="Decrease quantity" onClick={() => changeQuantity(item, item.quantity - 1)} disabled={busy} className="p-2"><Minus className="size-4" /></button><span className="w-6 text-center text-sm font-semibold">{item.quantity}</span><button aria-label="Increase quantity" onClick={() => changeQuantity(item, item.quantity + 1)} disabled={busy} className="p-2"><Plus className="size-4" /></button></div><button aria-label="Delete item" onClick={() => changeQuantity(item, 0)} disabled={busy} className="p-2 text-muted-foreground hover:text-destructive"><Trash2 className="size-4" /></button></div><input aria-label={`Notes for ${item.product?.[0]?.name ?? "item"}`} defaultValue={item.notes} onBlur={(event) => saveNotes(item, event.target.value)} disabled={busy} placeholder="Add a note" className="mt-2 w-full rounded-md border bg-background px-2 py-1.5 text-xs" /></div>)}</div><div className="border-t p-5"><div className="flex justify-between text-sm text-muted-foreground"><span>Subtotal</span><span>{money(subtotal)}</span></div><div className="mt-2 flex justify-between text-lg font-bold"><span>Total</span><span>{money(subtotal)}</span></div>{message && <p role="status" className="mt-3 text-sm text-muted-foreground">{message}</p>}<Button onClick={saveOrder} disabled={!activeOrder || busy} className="mt-4 w-full">{busy ? "Saving…" : "Save order"}</Button></div></aside></div></section>;
}

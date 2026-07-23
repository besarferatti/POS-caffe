# POS Caffè

A single-client, Supabase-backed restaurant POS. The floor editor remains the source of layout geometry; each saved table object's immutable UUID is the order key. Visible labels are presentation only.

## Setup

1. Create `.env.local` from `.env.example` and supply `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.
2. Apply the ordered migrations, then optionally seed a new development database:

   ```bash
   npx supabase db push
   npx supabase db execute --file supabase/seed.sql
   ```

   `database-setup.sql` is a convenience concatenation of the same migrations for a fresh Supabase SQL-editor installation. Do **not** run it against a database that already has migration history; use `supabase db push` instead.
3. Create the first account with Supabase Auth and promote it to admin:

   ```sql
   update public.profiles set role = 'admin' where id = '<auth-user-uuid>';
   ```

## Database delivery

The current migration set includes authentication and roles, core catalog and orders, migration of orders to floor-object UUIDs, then `20260723030000_add_order_status_values.sql` **by itself**, followed by `20260723031000_pos_operational_hardening.sql` for catalog metadata, active-order concurrency, reservations, payment records, printer queue/attempt history, audit data, and permission-based RLS. Existing databases must be upgraded only through these chronological migration files; never use `database-setup.sql` there.

The print queue intentionally has no browser-side hardware provider. A local authenticated print agent must claim `pending` jobs, submit the job's `idempotency_key` to the configured internal or fiscal adapter, and write a `print_attempt` plus either `printed` (with the real device response) or `failed` (with the failure reason). An agent retry must reuse the idempotency key; it must not infer success when the device is unreachable.

## Current operational scope and limitations

- The Orders screen renders all saved floor objects read-only, preserves geometry and stacking, uses immutable table UUIDs, and derives occupied/reserved state from active orders and reservations.
- The floor editor remains unchanged in interaction model, now retains stacking metadata and supports dividers. A legacy round table without a label is given an editable display label without changing its UUID.
- The schema exposes payment, print, reservation, and audit primitives with RLS. Full product administration, payment/split/refund UI, inventory, shifts, reports, settings, localized UI, and a deployable local print-agent service still require implementation; no hardware success is simulated.

## Checks

```bash
npm run typecheck
npm run lint
npm run build
```

# POS Caffè — Phase 1

The Phase 1 foundation is a single **Next.js App Router** application backed by Supabase. It establishes strict TypeScript, Tailwind CSS, shadcn/ui configuration, Supabase SSR authentication, roles, permissions, protected routes, and database migrations. It deliberately does **not** implement POS ordering, floor plans, inventory, reports, printers, or the other deferred product features.

## Prerequisites

- Node.js 20.9 or later
- npm 10 or later
- A Supabase project and (optional, for local database work) the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)

## Setup

1. Install dependencies:

   ```bash
   npm install
   ```

2. Create your local environment file and enter the project URL and publishable/anon key from Supabase Dashboard → Project Settings → API:

   ```bash
   cp .env.example .env.local
   ```

3. Apply the migration and seed data. For a linked remote project:

   ```bash
   npx supabase db push
   npx supabase db execute --file supabase/seed.sql
   ```

   For local development, run `npx supabase start`, then `npx supabase db reset`. The reset process applies `supabase/migrations` and `supabase/seed.sql`.

4. Start the app:

   ```bash
   npm run dev
   ```

## Authentication and authorization

- `/login` signs users in with Supabase email/password authentication.
- `/app` and its descendants are protected by middleware and a server-side profile check.
- An `auth.users` trigger creates a matching `public.profiles` row with the `worker` role for each new account.
- Roles are `admin`, `manager`, and `worker`. The seeded permission matrix is the source of record in the database; the TypeScript permission helper mirrors it for server-rendered navigation and route guards.
- Promote the first account to administrator in the Supabase SQL editor after it signs in:

  ```sql
  update public.profiles set role = 'admin' where id = '<auth-user-uuid>';
  ```

Row-level security permits each user to read their own profile, allows managers and administrators to read staff profiles, and only allows administrators to change profiles. Direct table writes are therefore not a substitute for a future admin-user provisioning flow.

## Checks

```bash
npm run lint
npm run typecheck
npm run build
```

-- This migration must complete before any constraint, index, function, or DML
-- references the new enum labels.  Supabase applies each migration separately.
alter type public.order_status add value if not exists 'sent';
alter type public.order_status add value if not exists 'partially_paid';
alter type public.order_status add value if not exists 'paid';
alter type public.order_status add value if not exists 'voided';
alter type public.order_status add value if not exists 'internal_only';

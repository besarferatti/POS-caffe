-- Catalog management integrity. Existing catalog data is retained; duplicates must be resolved before applying if present.
create unique index if not exists categories_name_case_insensitive_unique
  on public.categories ((lower(btrim(name))));

-- Empty optional identifiers are normalized so the partial unique indexes consistently mean "when provided".
update public.products set sku = null where sku is not null and btrim(sku) = '';
update public.products set barcode = null where barcode is not null and btrim(barcode) = '';

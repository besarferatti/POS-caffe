export const currencyCode = "MKD";
export const currencyLocale = "mk-MK";

const currencyFormatter = new Intl.NumberFormat(currencyLocale, {
  style: "currency",
  currency: currencyCode,
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
});

/** Formats numeric database amounts for display without changing their value. */
export function formatCurrency(amount: number): string {
  return currencyFormatter.format(amount).replace(/ден\.$/, "ден");
}

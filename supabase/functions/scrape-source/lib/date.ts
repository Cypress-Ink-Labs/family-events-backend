export function parseDateFromText(value: string): string | null {
  const datePattern =
    /\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?\b/i

  const match = value.match(datePattern)
  if (!match) {
    return null
  }

  const parsed = new Date(match[0])
  if (Number.isNaN(parsed.getTime())) {
    return null
  }
  return parsed.toISOString()
}

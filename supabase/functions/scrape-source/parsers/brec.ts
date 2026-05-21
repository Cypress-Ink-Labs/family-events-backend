import { DOMParser, type Element } from "@b-fuze/deno-dom";
import {
  cleanDescription,
  extractPrice,
  normalizeExtractedText,
  stripHtml,
} from "../../_shared/parsing.ts";
import { validateExternalUrl } from "../../_shared/url-validation.ts";
import type { ParsedEvent } from "../lib/types.ts";
import type { SourceParser } from "./_lib/types.ts";

const MONTHS: Record<string, number> = {
  january: 0,
  february: 1,
  march: 2,
  april: 3,
  may: 4,
  june: 5,
  july: 6,
  august: 7,
  september: 8,
  october: 9,
  november: 10,
  december: 11,
};

function parseDayHeading(text: string): { y: number; m: number; d: number } | null {
  // Example: "Friday, May 1, 2026"
  const match = text.match(/(?:^|,\s*)([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})/);
  if (!match) return null;
  const month = MONTHS[match[1].toLowerCase()];
  if (month === undefined) return null;
  const day = Number(match[2]);
  const year = Number(match[3]);
  if (!Number.isFinite(day) || !Number.isFinite(year)) return null;
  return { y: year, m: month, d: day };
}

function parseClock(value: string): { hour: number; minute: number } | null {
  const match = value.trim().match(/^(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m?\.?$/i);
  if (!match) return null;
  let hour = Number(match[1]);
  const minute = match[2] ? Number(match[2]) : 0;
  if (hour < 1 || hour > 12 || minute < 0 || minute > 59) return null;
  const period = match[3].toLowerCase();
  if (period === "p" && hour !== 12) hour += 12;
  if (period === "a" && hour === 12) hour = 0;
  return { hour, minute };
}

function getTimeZoneOffset(date: Date, timeZone: string): number {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = formatter.formatToParts(date);
  const pick = (t: string) =>
    Number(parts.find((p) => p.type === t)?.value);
  const asUtc = Date.UTC(
    pick("year"),
    pick("month") - 1,
    pick("day"),
    pick("hour"),
    pick("minute"),
    pick("second"),
  );
  return asUtc - date.getTime();
}

function localToIso(
  y: number,
  m: number,
  d: number,
  hour: number,
  minute: number,
  timeZone: string,
): string {
  const utcGuess = Date.UTC(y, m, d, hour, minute, 0);
  try {
    const initialOffset = getTimeZoneOffset(new Date(utcGuess), timeZone);
    let adjusted = utcGuess - initialOffset;
    const followupOffset = getTimeZoneOffset(new Date(adjusted), timeZone);
    if (followupOffset !== initialOffset) {
      adjusted = utcGuess - followupOffset;
    }
    return new Date(adjusted).toISOString();
  } catch {
    return new Date(utcGuess).toISOString();
  }
}

function parseTimeRange(
  date: { y: number; m: number; d: number },
  raw: string,
  timeZone: string,
): { startDatetime: string; endDatetime: string | null } {
  // BREC formats:
  //   "all day"
  //   "7:30 AM <br>-<br> 3:30 PM"  -> already br-stripped by stripHtml/normalize
  //   "9:00 AM"
  const normalized = normalizeExtractedText(raw).replace(/\s+/g, " ").trim();
  if (!normalized || /^all\s*day$/i.test(normalized)) {
    return {
      startDatetime: localToIso(date.y, date.m, date.d, 0, 0, timeZone),
      endDatetime: localToIso(date.y, date.m, date.d, 23, 59, timeZone),
    };
  }
  const [rawStart, rawEnd] = normalized.split(/\s*(?:-|–|—|to)\s*/i);
  const startClock = parseClock(rawStart ?? "");
  if (!startClock) {
    return {
      startDatetime: localToIso(date.y, date.m, date.d, 0, 0, timeZone),
      endDatetime: null,
    };
  }
  const startDatetime = localToIso(
    date.y,
    date.m,
    date.d,
    startClock.hour,
    startClock.minute,
    timeZone,
  );
  const endClock = parseClock(rawEnd ?? "");
  let endDatetime = endClock
    ? localToIso(date.y, date.m, date.d, endClock.hour, endClock.minute, timeZone)
    : null;
  if (
    endDatetime &&
    new Date(endDatetime).getTime() <= new Date(startDatetime).getTime()
  ) {
    endDatetime = new Date(
      new Date(endDatetime).getTime() + 24 * 60 * 60 * 1000,
    ).toISOString();
  }
  return { startDatetime, endDatetime };
}

function resolveUrl(href: string | null, base: string): string | null {
  if (!href) return null;
  try {
    return new URL(href, base).toString();
  } catch {
    return null;
  }
}

function extractArticleImage(article: Element, base: string): string | null {
  const img = article.querySelector("img");
  const src = img?.getAttribute("src");
  if (!src) return null;
  const url = resolveUrl(src, base);
  return url && validateExternalUrl(url).ok ? url : null;
}

export function parseBrecCalendar(
  html: string,
  sourceUrl: string,
  timeZone = "America/Chicago",
): ParsedEvent[] {
  const doc = new DOMParser().parseFromString(html, "text/html");
  if (!doc) return [];

  const events: ParsedEvent[] = [];
  const seenKeys = new Set<string>();
  // The events-list container interleaves <header class="day-header"> with
  // sibling <article> blocks until the next day-header.
  const lists = doc.querySelectorAll(".events-list");
  for (const list of lists) {
    let currentDate: { y: number; m: number; d: number } | null = null;
    for (const child of (list as Element).children) {
      if (child.classList.contains("day-header")) {
        const heading = child.querySelector("h2")?.textContent ?? "";
        currentDate = parseDayHeading(heading);
        continue;
      }
      if (child.tagName?.toLowerCase() !== "article" || !currentDate) {
        continue;
      }
      const article = child;
      const title = stripHtml(
        article.querySelector("h3")?.textContent ?? "",
      ).trim();
      if (!title) continue;

      const timeText = article.querySelector(".time")?.textContent ?? "";
      const { startDatetime, endDatetime } = parseTimeRange(
        currentDate,
        timeText,
        timeZone,
      );

      const venueName = stripHtml(
        article.querySelector(".park")?.textContent ?? "",
      ).trim() || null;

      const linkHref = article.querySelector("a[href]")?.getAttribute("href") ??
        null;
      const eventUrl = resolveUrl(linkHref, sourceUrl);

      const dayIndex = stripHtml(
        article.querySelector(".day-index")?.textContent ?? "",
      ).trim();
      const description = cleanDescription(
        [venueName, dayIndex].filter(Boolean).join(" — "),
      ) || title;

      const imageUrl = extractArticleImage(article, sourceUrl);
      const priceInfo = extractPrice(description);

      const key = `${eventUrl ?? title}::${startDatetime}`;
      if (seenKeys.has(key)) continue;
      seenKeys.add(key);

      events.push({
        title,
        description: description.slice(0, 500),
        startDatetime,
        endDatetime,
        venueName,
        address: venueName,
        sourceUrl: eventUrl,
        imageUrl,
        images: imageUrl ? [imageUrl] : [],
        price: priceInfo.price,
        isFree: priceInfo.isFree,
      });
    }
  }

  return events;
}

export const brecParser: SourceParser<"brec"> = {
  type: "brec",
  async fetchArtifact(source, ctx) {
    const html = await ctx.fetchText(source.url, {
      accept: "text/html,application/xhtml+xml,*/*",
    });
    return { url: source.url, contentType: "text/html", body: html };
  },
  extractEvents(source, artifact, ctx) {
    return Promise.resolve(
      parseBrecCalendar(artifact.body, artifact.url || source.url, ctx.timezone),
    );
  },
  async fetchAndParse(source, ctx) {
    const artifact = await this.fetchArtifact(source, ctx);
    return this.extractEvents(source, artifact, ctx);
  },
};

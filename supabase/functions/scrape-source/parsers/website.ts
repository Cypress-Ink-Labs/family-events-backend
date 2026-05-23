import { DOMParser } from "@b-fuze/deno-dom";
import {
  cleanDescription,
  extractPrice,
  normalizeExtractedText,
  parseIsoDate,
  stripHtml,
} from "../../_shared/parsing.ts";
import { validateExternalUrl } from "../../_shared/url-validation.ts";
import { dateStampToWallClockIso } from "../lib/date.ts";
import type { ParsedEvent } from "../lib/types.ts";
import type { SourceParser } from "./_lib/types.ts";

type StructuredEvent = ParsedEvent & {
  sourceUrl: string | null;
};

function toArray(value: unknown): unknown[] {
  if (Array.isArray(value)) {
    return value;
  }
  return value === null || value === undefined ? [] : [value];
}

function eventNodes(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) {
    return value.flatMap((item) => eventNodes(item));
  }
  if (!value || typeof value !== "object") {
    return [];
  }

  const node = value as Record<string, unknown>;
  const typeValues = toArray(node["@type"]).map((entry) =>
    String(entry).toLowerCase()
  );
  const isEvent = typeValues.some((entry) =>
    entry === "event" || entry.endsWith(":event")
  );
  // Descend into common JSON-LD wrappers that nest Event objects:
  // @graph, ItemList.itemListElement[].item, mainEntity, hasPart.
  // Eventbrite uses ItemList → ListItem.item where item is @type:Event.
  const nested = [
    ...eventNodes(node["@graph"]),
    ...eventNodes(node["itemListElement"]),
    ...eventNodes(node["item"]),
    ...eventNodes(node["mainEntity"]),
    ...eventNodes(node["hasPart"]),
  ];
  return isEvent ? [node, ...nested] : nested;
}

function pickText(value: unknown): string | null {
  if (typeof value === "string") {
    const trimmed = stripHtml(value);
    return trimmed.length > 0 ? trimmed : null;
  }
  if (value && typeof value === "object") {
    const node = value as Record<string, unknown>;
    return pickText(node["@value"] ?? node.name ?? node.text);
  }
  return null;
}

function extractImageUrls(value: unknown): string[] {
  if (typeof value === "string") {
    return [value];
  }
  if (Array.isArray(value)) {
    return value.flatMap((entry) => extractImageUrls(entry));
  }
  if (value && typeof value === "object") {
    const node = value as Record<string, unknown>;
    return extractImageUrls(node.url ?? node.contentUrl);
  }
  return [];
}

function parseClock(value: string): { hour: number; minute: number } | null {
  const match = value.trim().match(
    /^(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m?\.?$/i,
  );
  if (!match) {
    return null;
  }

  let hour = Number(match[1]);
  const minute = match[2] ? Number(match[2]) : 0;
  if (hour < 1 || hour > 12 || minute < 0 || minute > 59) {
    return null;
  }

  const period = match[3].toLowerCase();
  if (period === "p" && hour !== 12) {
    hour += 12;
  }
  if (period === "a" && hour === 12) {
    hour = 0;
  }

  return { hour, minute };
}

function parseMecTimeRange(
  dateStamp: string,
  rawTime: string,
  timeZone: string,
): { startDatetime: string; endDatetime: string | null } | null {
  const normalized = normalizeExtractedText(rawTime)
    .replace(/^[^\d]+/, "")
    .replace(/\s+/g, " ");
  const [rawStart, rawEnd] = normalized.split(/\s*(?:-|–|—|to)\s*/i);
  const startClock = parseClock(rawStart ?? "");
  if (!startClock) {
    return null;
  }

  const startDatetime = dateStampToWallClockIso(
    dateStamp,
    startClock.hour,
    startClock.minute,
    timeZone,
  );
  if (!startDatetime) {
    return null;
  }

  const endClock = parseClock(rawEnd ?? "");
  let endDatetime = endClock
    ? dateStampToWallClockIso(
      dateStamp,
      endClock.hour,
      endClock.minute,
      timeZone,
    )
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

function normalizeUrl(value: string | null, baseUrl: string): string | null {
  if (!value) {
    return null;
  }
  try {
    return new URL(value, baseUrl).toString();
  } catch {
    return null;
  }
}

function offerPrice(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function parseStructuredEvents(
  doc: ReturnType<DOMParser["parseFromString"]>,
  sourceUrl: string,
): StructuredEvent[] {
  if (!doc) {
    return [];
  }

  const eventCandidates: Record<string, unknown>[] = [];
  for (
    const script of doc.querySelectorAll('script[type="application/ld+json"]')
  ) {
    const rawJson = script.textContent?.trim() ?? "";
    if (!rawJson) {
      continue;
    }

    try {
      const parsed = JSON.parse(rawJson);
      eventCandidates.push(...eventNodes(parsed));
    } catch {
      continue;
    }
  }

  const events: StructuredEvent[] = [];
  for (const candidate of eventCandidates) {
    const title = pickText(candidate.name);
    if (!title) {
      continue;
    }

    const startDatetime = parseIsoDate(pickText(candidate.startDate));
    if (!startDatetime) {
      continue;
    }

    const endDatetime = parseIsoDate(pickText(candidate.endDate));
    const description = cleanDescription(pickText(candidate.description)) ||
      title;
    const eventUrl = normalizeUrl(pickText(candidate.url), sourceUrl) ??
      sourceUrl;
    const venueName = pickText(
      (candidate.location as Record<string, unknown> | undefined)?.name,
    ) ??
      pickText(candidate.location);
    const address = pickText(
      (candidate.location as Record<string, unknown> | undefined)?.address,
    ) ??
      pickText(
        (candidate.location as Record<string, unknown> | undefined)
          ?.["streetAddress"],
      ) ??
      venueName;

    const webImages: string[] = [];
    for (const image of extractImageUrls(candidate.image)) {
      const normalized = normalizeUrl(image, sourceUrl);
      if (
        normalized && validateExternalUrl(normalized).ok &&
        !webImages.includes(normalized)
      ) {
        webImages.push(normalized);
      }
      if (webImages.length >= 5) {
        break;
      }
    }

    const offers = candidate.offers as Record<string, unknown> | undefined;
    const priceFromOffers = offerPrice(offers?.price);
    const isFreeFromOffers = priceFromOffers === 0;
    const priceInfo = extractPrice(description);

    events.push({
      title,
      description: description.slice(0, 500),
      startDatetime,
      endDatetime,
      venueName,
      address,
      sourceUrl: eventUrl,
      imageUrl: webImages[0] ?? null,
      images: webImages,
      price: priceFromOffers ?? priceInfo.price,
      isFree: isFreeFromOffers || priceInfo.isFree,
    });
  }

  return events;
}

function parseMecCalendarEvents(
  doc: ReturnType<DOMParser["parseFromString"]>,
  sourceUrl: string,
  timeZone: string,
  structuredEvents: StructuredEvent[],
): ParsedEvent[] {
  if (!doc) {
    return [];
  }

  const structuredByUrl = new Map(
    structuredEvents
      .filter((event) => event.sourceUrl)
      .map((event) => [event.sourceUrl as string, event]),
  );
  const seenKeys = new Set<string>();
  const events: ParsedEvent[] = [];

  for (
    const dayNode of doc.querySelectorAll(".mec-calendar-day[data-mec-cell]")
  ) {
    const dateStamp = dayNode.getAttribute("data-mec-cell") ?? "";
    for (
      const link of dayNode.querySelectorAll(
        "a.event-single-link-simple[data-tooltip-content]",
      )
    ) {
      const title = pickText(
        link.querySelector(".mec-event-title")?.textContent,
      );
      if (!title) {
        continue;
      }

      const tooltipSelector = link.getAttribute("data-tooltip-content");
      const tooltip = tooltipSelector
        ? doc.querySelector(tooltipSelector)
        : null;
      const parsedTime = parseMecTimeRange(
        dateStamp,
        tooltip?.querySelector(".mec-tooltip-event-time")?.textContent ?? "",
        timeZone,
      );
      if (!parsedTime) {
        continue;
      }

      const eventUrl = normalizeUrl(link.getAttribute("href"), sourceUrl) ??
        sourceUrl;
      const structured = structuredByUrl.get(eventUrl);
      const rawDescription =
        tooltip?.querySelector(".mec-tooltip-event-desc")?.textContent ?? "";
      const description = structured?.description ??
        cleanDescription(rawDescription.replace(/\s*,\s*\.\.\.$/, ""));
      const tooltipImage = tooltip?.querySelector("img")?.getAttribute("src") ??
        null;
      const imageUrl = structured?.imageUrl ??
        normalizeUrl(tooltipImage, sourceUrl);
      const images = structured?.images.length
        ? structured.images
        : imageUrl
        ? [imageUrl]
        : [];
      const priceInfo = extractPrice(description);

      const key = `${eventUrl}::${parsedTime.startDatetime}`;
      if (seenKeys.has(key)) {
        continue;
      }

      seenKeys.add(key);
      events.push({
        title,
        description: description.slice(0, 500),
        startDatetime: parsedTime.startDatetime,
        endDatetime: parsedTime.endDatetime,
        venueName: structured?.venueName ?? null,
        address: structured?.address ?? structured?.venueName ?? null,
        sourceUrl: eventUrl,
        imageUrl,
        images,
        price: structured?.price ?? priceInfo.price,
        isFree: structured?.isFree ?? priceInfo.isFree,
      });
    }
  }

  return events;
}

export function parseWebsite(
  html: string,
  sourceUrl: string,
  timeZone = "UTC",
): ParsedEvent[] {
  const parser = new DOMParser();
  const doc = parser.parseFromString(html, "text/html");
  if (!doc) {
    return [];
  }

  const structuredEvents = parseStructuredEvents(doc, sourceUrl);
  const mecEvents = parseMecCalendarEvents(
    doc,
    sourceUrl,
    timeZone,
    structuredEvents,
  );
  if (mecEvents.length > 0) {
    return mecEvents;
  }

  const seenKeys = new Set<string>();
  const events: ParsedEvent[] = [];
  for (const structured of structuredEvents) {
    const key =
      `${structured.title.toLowerCase()}::${structured.startDatetime}`;
    if (seenKeys.has(key)) {
      continue;
    }
    seenKeys.add(key);
    events.push(structured);
  }

  return events;
}

export const websiteParser: SourceParser<"website"> = {
  type: "website",
  async fetchArtifact(source, ctx) {
    const html = await ctx.fetchText(source.url, {
      accept: "text/html,application/xml,text/xml,*/*",
    });
    return { url: source.url, contentType: "text/html", body: html };
  },
  extractEvents(source, artifact, ctx) {
    return Promise.resolve(
      parseWebsite(artifact.body, artifact.url || source.url, ctx.timezone),
    );
  },
};

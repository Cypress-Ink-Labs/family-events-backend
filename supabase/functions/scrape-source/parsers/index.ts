import type { SourceParser } from "./_lib/types.ts";
import type { SourceType } from "../lib/types.ts";
import { websiteParser } from "./website.ts";
import { rssParser } from "./rss.ts";
import { icalParser } from "./ical.ts";
import { manualParser } from "./manual.ts";
import { macaroniKidParser } from "./macaroni-kid.ts";
import { brecParser } from "./brec.ts";
import { downtownLafayetteParser } from "./downtownlafayette.ts";
import { lcgLafayetteParser } from "./lcg-lafayette.ts";
import { localHopParser } from "./localhop.ts";

export const parsers = {
  [websiteParser.type]: websiteParser,
  [rssParser.type]: rssParser,
  [icalParser.type]: icalParser,
  [manualParser.type]: manualParser,
  [macaroniKidParser.type]: macaroniKidParser,
  [brecParser.type]: brecParser,
  [downtownLafayetteParser.type]: downtownLafayetteParser,
  [lcgLafayetteParser.type]: lcgLafayetteParser,
  [localHopParser.type]: localHopParser,
} as const satisfies Record<SourceType, SourceParser>;

export type { SourceParser } from "./_lib/types.ts";
export type { ParserContext } from "../lib/parser-context.ts";

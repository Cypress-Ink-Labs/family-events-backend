import type { SourceParser } from "./_lib/types.ts"
import { websiteParser } from "./website.ts"
import { rssParser } from "./rss.ts"
import { icalParser } from "./ical.ts"
import { manualParser } from "./manual.ts"
import { macaroniKidParser } from "./macaroni-kid.ts"
import { brecParser } from "./brec.ts"

export const parsers = {
  [websiteParser.type]: websiteParser,
  [rssParser.type]: rssParser,
  [icalParser.type]: icalParser,
  [manualParser.type]: manualParser,
  [macaroniKidParser.type]: macaroniKidParser,
  [brecParser.type]: brecParser,
} as const satisfies Record<string, SourceParser>

export type SourceType = keyof typeof parsers

export type { SourceParser } from "./_lib/types.ts"
export type { ParserContext } from "./_lib/context.ts"

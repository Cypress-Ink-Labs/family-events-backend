import type {
  EventSourceRow,
  FetchedArtifact,
  ParsedEvent,
} from "../../lib/types.ts";
import type { ParserContext } from "./context.ts";

export interface SourceParser<T extends string = string> {
  readonly type: T;
  fetchArtifact(
    source: EventSourceRow,
    ctx: ParserContext,
  ): Promise<FetchedArtifact>;
  extractEvents(
    source: EventSourceRow,
    artifact: FetchedArtifact,
    ctx: ParserContext,
  ): Promise<ParsedEvent[]>;
  fetchAndParse(
    source: EventSourceRow,
    ctx: ParserContext,
  ): Promise<ParsedEvent[]>;
}

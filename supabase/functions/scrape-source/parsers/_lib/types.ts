import type {
  EventSourceRow,
  FetchedArtifact,
  ParsedEvent,
} from "../../lib/types.ts";
import type { ParserContext } from "../../lib/parser-context.ts";

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
}

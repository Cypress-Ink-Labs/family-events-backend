import type { EventSourceRow, ParsedEvent } from "../../lib/types.ts"
import type { ParserContext } from "./context.ts"

export interface SourceParser<T extends string = string> {
  readonly type: T
  fetchAndParse(source: EventSourceRow, ctx: ParserContext): Promise<ParsedEvent[]>
}

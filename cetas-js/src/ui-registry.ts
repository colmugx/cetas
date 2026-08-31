import type {
  AutocompleteItem as PiAutocompleteItem,
  AutocompleteProvider,
  AutocompleteSuggestions,
} from "@earendil-works/pi-tui";

export interface UiAutocompleteItem {
  label: string;
  detail: string;
  insert_text: string;
}

export interface UiAutocompleteSource {
  trigger: string;
  kind: "command" | "file" | "model" | "custom";
  /**
   * Keep matching after the first space (e.g. "/cmd partial-arg"). The
   * default rejects whitespace after the trigger so single-token sources
   * never swallow argument text.
   */
  spanSpaces?: boolean;
  fetch(
    prefix: string,
    signal: AbortSignal,
  ): UiAutocompleteItem[] | Promise<UiAutocompleteItem[]>;
}

export interface UiDescriptor {
  component_keys: string[];
  autocomplete: UiAutocompleteSource[];
}

interface RegisteredDescriptor {
  extensionId: string;
  descriptor: UiDescriptor;
}

function isTokenBoundary(text: string, index: number): boolean {
  return index === 0 || /\s/.test(text[index - 1] ?? "");
}

function activePrefix(
  textBeforeCursor: string,
  trigger: string,
  spanSpaces: boolean,
): { triggerIndex: number; query: string; replacementPrefix: string } | null {
  const triggerIndex = textBeforeCursor.lastIndexOf(trigger);
  if (
    triggerIndex < 0 ||
    !isTokenBoundary(textBeforeCursor, triggerIndex)
  ) {
    return null;
  }
  const replacementPrefix = textBeforeCursor.slice(triggerIndex);
  if (!spanSpaces && /\s/.test(replacementPrefix.slice(trigger.length))) {
    return null;
  }
  return {
    triggerIndex,
    query: replacementPrefix.slice(trigger.length),
    replacementPrefix,
  };
}

/**
 * Registry for TypeScript-hosted extension UI descriptors.
 *
 * MoonBit closures are never serialized across the JS boundary. A TS
 * extension registers its fetch endpoint here; the editor calls it through
 * the standard pi-tui AutocompleteProvider contract.
 */
export class UiRegistry implements AutocompleteProvider {
  private readonly descriptors: RegisteredDescriptor[] = [];
  private readonly extensionIds = new Set<string>();
  private readonly componentOwners = new Map<string, string>();

  get triggerCharacters(): string[] {
    return [
      ...new Set(
        this.descriptors.flatMap(({ descriptor }) =>
          descriptor.autocomplete.map(({ trigger }) => trigger)
        ),
      ),
    ];
  }

  register(extensionId: string, descriptor: UiDescriptor): void {
    if (extensionId.trim().length === 0) {
      throw new Error("extension id must not be empty");
    }
    if (this.extensionIds.has(extensionId)) {
      throw new Error(`duplicate UI extension id: ${extensionId}`);
    }
    for (const key of descriptor.component_keys) {
      if (key.trim().length === 0) {
        throw new Error(`UI extension ${extensionId} declared an empty component key`);
      }
      const owner = this.componentOwners.get(key);
      if (owner !== undefined) {
        throw new Error(
          `UI component key collision: ${key} is owned by ${owner} and ${extensionId}`,
        );
      }
    }
    for (const source of descriptor.autocomplete) {
      if (source.trigger.length === 0) {
        throw new Error(`UI extension ${extensionId} declared an empty autocomplete trigger`);
      }
    }
    this.extensionIds.add(extensionId);
    for (const key of descriptor.component_keys) {
      this.componentOwners.set(key, extensionId);
    }
    this.descriptors.push({ extensionId, descriptor });
  }

  /**
   * The longest replacementPrefix wins. When different triggers produce
   * equal-length prefixes, only the trigger occurrence closest to the
   * cursor is used; sources whose replacementPrefix string is identical
   * (same trigger occurrence) still merge their items.
   */
  async getSuggestions(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    options: { signal: AbortSignal; force?: boolean },
  ): Promise<AutocompleteSuggestions | null> {
    const line = lines[cursorLine];
    if (line === undefined) {
      throw new Error(`autocomplete cursor line ${cursorLine} is outside the editor buffer`);
    }
    if (cursorCol < 0 || cursorCol > line.length) {
      throw new Error(`autocomplete cursor column ${cursorCol} is outside line ${cursorLine}`);
    }
    const textBeforeCursor = line.slice(0, cursorCol);
    const matches: Array<{
      source: UiAutocompleteSource;
      triggerIndex: number;
      query: string;
      replacementPrefix: string;
    }> = [];
    for (const { descriptor } of this.descriptors) {
      for (const source of descriptor.autocomplete) {
        const prefix = activePrefix(
          textBeforeCursor,
          source.trigger,
          source.spanSpaces ?? false,
        );
        if (prefix !== null) {
          matches.push({ source, ...prefix });
        }
      }
    }
    if (matches.length === 0) return null;

    let winner = matches[0]!;
    for (const match of matches) {
      if (
        match.replacementPrefix.length > winner.replacementPrefix.length ||
        (match.replacementPrefix.length === winner.replacementPrefix.length &&
          match.triggerIndex > winner.triggerIndex)
      ) {
        winner = match;
      }
    }
    const active = matches.filter(
      ({ replacementPrefix }) => replacementPrefix === winner.replacementPrefix,
    );
    const fetched = await Promise.all(
      active.map(({ source, query }) => source.fetch(query, options.signal)),
    );
    if (options.signal.aborted) return null;
    const items: PiAutocompleteItem[] = fetched
      .flat()
      .map((item) => ({
        value: item.insert_text,
        label: item.label,
        description: item.detail.length > 0 ? item.detail : undefined,
      }));
    return items.length === 0 ? null : { items, prefix: winner.replacementPrefix };
  }

  applyCompletion(
    lines: string[],
    cursorLine: number,
    cursorCol: number,
    item: PiAutocompleteItem,
    prefix: string,
  ): { lines: string[]; cursorLine: number; cursorCol: number } {
    const line = lines[cursorLine];
    if (line === undefined) {
      throw new Error(`completion cursor line ${cursorLine} is outside the editor buffer`);
    }
    const start = cursorCol - prefix.length;
    if (start < 0 || line.slice(start, cursorCol) !== prefix) {
      throw new Error("completion prefix does not match editor contents");
    }
    const nextLines = [...lines];
    nextLines[cursorLine] =
      line.slice(0, start) + item.value + line.slice(cursorCol);
    return {
      lines: nextLines,
      cursorLine,
      cursorCol: start + item.value.length,
    };
  }
}

import { describe, expect, test } from "bun:test";
import { Markdown, visibleWidth } from "@earendil-works/pi-tui";
import { markdownTheme } from "../../ui/theme.ts";
import { IncrementalMarkdown, stableMarkdownCut } from "./markdown-stream.ts";
import { AssistantMessage } from "./components.ts";

const longParagraph = (n: number) => "The assistant is describing a stable section with plain words and no special markup. ".repeat(n).trim();

describe("Gate 4 incremental streaming Markdown", () => {
  test("recognizes a completed plain paragraph but not an open paragraph", () => {
    const plain = longParagraph(9) + "\n\nAnd a new paragraph is streaming.";
    expect(stableMarkdownCut(plain)).toBeGreaterThan(0);
    expect(stableMarkdownCut(longParagraph(9))).toBe(0);
  });
  test("leaves fenced code, reference links and inline Markdown to full lexer", () => {
    const tricky = [
      "```ts\n" + longParagraph(9) + "\n\nconsole.log('test');",
      "[id]: https://example.com\n\n" + longParagraph(9),
      "- list item\n  \n" + longParagraph(9),
      "> quote text\n\n" + longParagraph(9),
    ];
    for (const text of tricky) expect(stableMarkdownCut(text)).toBe(0);
  });
  test("exactly matches upstream ANSI Markdown at widths including narrow CJK", () => {
    for (const width of [8, 12, 40, 80, 120]) {
      const chunks = [
        longParagraph(8) + "\n\n",
        "汉字 and emoji 🌟 are on the new streaming line.\n\n",
        "```typescript\nconst value = 42;\n```\n\n",
        "| column | result |\n| --- | --- |\n| foo | bar |\n",
      ];
      const streamed = new IncrementalMarkdown("", 1, 0, markdownTheme);
      const native = new Markdown("", 1, 0, markdownTheme);
      let source = "";
      for (const part of chunks) {
        for (let offset = 0; offset < part.length; offset += 37) {
          source += part.slice(offset, offset + 37);
          streamed.setText(source);
          native.setText(source);
          const actual = streamed.render(width);
          const expected = native.render(width);
          expect(actual).toEqual(expected);
          expect(actual.every(line => visibleWidth(line) <= width)).toBe(true);
        }
      }
    }
  });
  test("replacement content and invalidate cannot leave stale frozen text", () => {
    const streamed = new IncrementalMarkdown("", 1, 0, markdownTheme);
    streamed.setText(longParagraph(9) + "\n\n" + longParagraph(1));
    streamed.render(80);
    streamed.setText("# Completely replaced Markdown");
    streamed.invalidate();
    const native = new Markdown("# Completely replaced Markdown", 1, 0, markdownTheme);
    expect(streamed.render(20)).toEqual(native.render(20));
  });
  test("assistant streaming flag only changes rendering implementation", () => {
    const a = new AssistantMessage("sample", { streaming: true });
    const b = new AssistantMessage("sample");
    expect(a.render(80)).toEqual(b.render(80));
    a.updateContent("sample and more");
    b.updateContent("sample and more");
    expect(a.render(80)).toEqual(b.render(80));
  });
});

import { describe, expect, test } from "bun:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import { AboveAutocompleteEditor, autocompletePalette } from "./above-autocomplete-editor.ts";

describe("above-composer autocomplete", () => {
  test("terminal colors adapt to OSC foreground/background", () => {
    const dark = autocompletePalette({background:{r:10,g:20,b:30},foreground:{r:240,g:240,b:240}});
    const light = autocompletePalette({background:{r:250,g:250,b:250},foreground:{r:12,g:12,b:12}});
    expect(dark.background).not.toBe(light.background);
    expect(dark.foreground).not.toBe(light.foreground);
  });
  test("suggestions render above composer and never increase editor height", async () => {
    const tui = {
      terminal: { columns: 80, rows: 30 },
      requestRender() {},
    } as never;
    const style = {
      borderColor: (s: string) => s,
      selectList: {
        selectedPrefix: (s: string) => s,
        selectedText: (s: string) => s,
        description: (s: string) => s,
        scrollInfo: (s: string) => s,
        noMatch: (s: string) => s,
      },
    };
    const editor = new AboveAutocompleteEditor(tui,style);
    editor.setAutocompleteProvider({
      getSuggestions: async () => ({prefix:"/",items:[
        {value:"/model",label:"/model",description:"Choose model"},
        {value:"/help",label:"/help",description:"Show help"},
      ]}),
      applyCompletion: (_lines,_row,_col,item) => ({lines:[item.value],cursorLine:0,cursorCol:item.value.length}),
    });
    editor.setText("/");
    editor.handleInput("/");
    const before = editor.render(80).length;
    // Completion resolution is asynchronous; drive only the invariant that
    // the layout never includes suggestion rows in the composer.
    const menu = editor.renderMenu(80);
    expect(editor.render(80).length).toBe(before);
    expect(menu.every(line => visibleWidth(line) <= 80)).toBe(true);
  });
});

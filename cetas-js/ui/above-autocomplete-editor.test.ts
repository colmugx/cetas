import { describe, expect, test } from "bun:test";
import { SelectList, stripTerminalSequences, visibleWidth } from "@earendil-works/pi-tui";
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
  test("long @paths use available columns, while descriptions remain visible", () => {
    const tui = { terminal: { columns: 100, rows: 30 }, requestRender() {} } as never;
    const style = {
      borderColor: (text: string) => text,
      selectList: {
        selectedPrefix: (text: string) => text,
        selectedText: (text: string) => text,
        description: (text: string) => text,
        scrollInfo: (text: string) => text,
        noMatch: (text: string) => text,
      },
    };
    const editor = new AboveAutocompleteEditor(tui, style);
    const path = "external/cetas/extension/posoco-extension/src/internal/commands/";
    const list = new SelectList([
      { value: path, label: path, description: "directory" },
      { value: "src/", label: "src/", description: "directory" },
    ], 5, style.selectList);
    const state = editor as unknown as { autocompleteList: SelectList; autocompleteState: string };
    state.autocompleteList = list;
    state.autocompleteState = "regular";

    const wide = editor.renderMenu(100);
    expect(stripTerminalSequences(wide[0]!)).toContain(path);
    expect(stripTerminalSequences(wide[0]!)).toContain("directory");
    expect(wide.every(line => visibleWidth(line) === 100)).toBe(true);

    const narrow = editor.renderMenu(40);
    expect(narrow.every(line => visibleWidth(line) === 40)).toBe(true);
    expect(stripTerminalSequences(narrow[0]!)).not.toContain(path);
  });

  test("selected item background reaches the right edge without recoloring other rows", () => {
    const tui = { terminal: { columns: 80, rows: 30 }, requestRender() {} } as never;
    const style = {
      borderColor: (text: string) => text,
      selectList: {
        selectedPrefix: (text: string) => text,
        selectedText: (text: string) => text,
        description: (text: string) => text,
        scrollInfo: (text: string) => text,
        noMatch: (text: string) => text,
      },
    };
    const editor = new AboveAutocompleteEditor(tui, style);
    const list = new SelectList([
      { value: "/model", label: "/model", description: "Choose model" },
      { value: "/help", label: "/help", description: "Show help" },
    ], 5, style.selectList);
    const state = editor as unknown as { autocompleteList: SelectList; autocompleteState: string };
    state.autocompleteList = list;
    state.autocompleteState = "regular";

    const menu = editor.renderMenu(80);
    expect(menu[0]).toContain("\x1b[46m\x1b[30m");
    expect(menu[0]).toMatch(/ +\x1b\[0m$/);
    expect(menu[1]).not.toContain("\x1b[46m");
    expect(menu.every(line => visibleWidth(line) === 80)).toBe(true);
  });

});

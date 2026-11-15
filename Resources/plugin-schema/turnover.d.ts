// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver plugin script interface, version 1 (docs/PLUGIN-SCRIPTS.md; written 15 Nov 2026 from
// docs/PLUGIN-SCRIPTS-PLAN.md). For editors and AI assistants. This file describes the design; scripts are off
// until the maintainer switches on `pluginScripts`.
//
// A script sees the global `turnover`, `console` and the four timers. Nothing else exists: no fetch, no require,
// no file or process objects.
//
// Each member's comment gives the ability it needs, from manifest.json's "abilities". A request without its ability
// rejects with an error that names the ability to add. Where the design does not say, the comment says so.

/** The abilities a manifest may list. `read`, `say`, `press`, `focus`, `menu` and `keys` are the data plugins' six. */
type Ability = "read" | "say" | "press" | "focus" | "menu" | "keys" | "edit" | "clipboard";

/**
 * A match, the same object profile.json uses (PLUGIN-GUIDE.md, "Matching elements"). Every field given must agree.
 * Text comparisons ignore case and `*` matches anything.
 */
interface Match {
  role?: string;
  roles?: string[];
  subrole?: string;
  identifier?: string;
  title?: string;
  description?: string;
  help?: string;
  value?: string;
  text?: string;
  window?: string;
  /** An ancestor that must match. */
  inside?: Match;
  /** The immediate parent must match. */
  parent?: Match;
  unnamed?: boolean;
  pressable?: boolean;
  /** Which of the matches: 1 is first, -1 is last. */
  nth?: number;
  /** A list of matches of which one must fit. */
  any?: Match[];
}

/**
 * An item: a copy of what was true when it was made, plus a handle. Reading the fields needs no ability (the
 * ability was needed to get the item). The field types below follow the plan's names; the plan gives no types.
 */
interface Item {
  /** The role as TurnOver would say it. */
  readonly role: string;
  /** The accessibility role, with its AX prefix. */
  readonly axRole: string;
  readonly subrole: string | null;
  readonly name: string | null;
  /** Always blank when `secure` is true. */
  readonly value: string | null;
  readonly description: string | null;
  /** The tooltip. */
  readonly help: string | null;
  /** The app's own identifier. */
  readonly identifier: string | null;
  readonly states: string[];
  readonly window: string | null;
  /** True for a secure field. A secure field is always blank to a plugin. */
  readonly secure: boolean;

  /** Ability: read. A fresh copy, or null if the item has gone. */
  refresh(): Promise<Item | null>;
  /** Ability: read. The item's parent. A handle the plugin was not given, or one in another app, rejects. */
  parent(): Promise<Item | null>;
  /** Ability: read. The first 200 children. */
  children(): Promise<Item[]>;
  /** Abilities: read and say. TurnOver reads the item its own way. */
  read(): Promise<void>;
  /** Ability: press. */
  press(): Promise<void>;
  /** Ability: focus. Moves the keyboard focus to the item. */
  focus(): Promise<void>;
  /** Ability: edit. Changes the item's text or value. */
  setValue(value: string): Promise<void>;
}

/**
 * What a `focus` or `valueChange` handler receives. The handler must decide before it returns: nothing after an
 * `await` can change the words. The handler has 25 ms to answer.
 */
interface ReplaceableEvent {
  readonly item: Item;
  /**
   * Replace what TurnOver says for the item. Which ability this needs is not stated in the plan (likely `say`).
   */
  say(text: string): void;
  /** Say nothing for the item. Which ability this needs is not stated in the plan (likely `say`). */
  silence(): void;
}

/** What `appFocus`, `appBlur` and `windowChange` handlers receive. There is nothing to replace. */
interface NoticeEvent {}

interface EventMap {
  /** An item in one of the plugin's apps took the focus. It never stops TurnOver's other handling of the focus. */
  focus: ReplaceableEvent;
  /** An item's value changed. A value change the script handles stops the chain, as a watch rule does. */
  valueChange: ReplaceableEvent;
  /** One of the plugin's apps came to the front. */
  appFocus: NoticeEvent;
  /** One of the plugin's apps went to the back. */
  appBlur: NoticeEvent;
  /** The window of one of the plugin's apps changed. */
  windowChange: NoticeEvent;
}

interface Storage {
  /**
   * Keeps the plugin's own data between runs, up to 256 KB. The plan lists no ability for it and does not say what
   * values it takes.
   */
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
  remove(key: string): Promise<void>;
}

interface Turnover {
  /** No ability. This plugin's own manifest fields. */
  readonly plugin: { id: string; name: string; version: string };
  /** No ability. The interface version: 1. */
  readonly api: 1;
  /** No ability. The language TurnOver is using, such as "en". */
  readonly language: string;

  /**
   * No ability to listen. Registers a handler for an event. Events are never sent for typed characters, caret
   * moves, or anything from an app the plugin did not name.
   * @example turnover.on("focus", (event) => { if (!event.item.name) event.say("Unnamed"); });
   */
  on<K extends keyof EventMap>(name: K, handler: (event: EventMap[K]) => void): void;

  /**
   * No ability to be called. Registers the handler for a command declared in manifest.json's "commands". What the
   * handler does needs its own abilities. The plan does not say what argument the handler receives; do not rely on
   * one. A command has 5 seconds to finish.
   * @example turnover.command("readResult", async () => { turnover.say("Hello"); });
   */
  command(id: string, handler: (...args: unknown[]) => void | Promise<void>): void;

  /**
   * Ability: say. Speaks the text. A script may say 20 things in two seconds, 500 characters each.
   * @example turnover.say("Saved", { interrupt: false });
   */
  say(text: string, options?: { interrupt?: boolean }): void;

  /**
   * Ability: say. Plays one of TurnOver's own sounds. The plan does not list the names.
   */
  sound(name: string): void;

  /**
   * Ability: read. The item with the keyboard focus, or null.
   * @example const item = await turnover.focused();
   */
  focused(): Promise<Item | null>;

  /**
   * Ability: read. Finds items in the plugin's apps. `limit` is the most to return. The plan does not state the
   * result's shape; a list of items is assumed.
   * @example const [save] = await turnover.find({ role: "button", identifier: "Save" }, { limit: 1 });
   */
  find(match: Match, options?: { limit?: number }): Promise<Item[]>;

  /**
   * Ability: menu. Chooses a command from the app's menus. PluginPolicy's refusals apply when the request is made:
   * the Apple menu, a first menu given as a pattern, and Paste, Log Out, Lock Screen, Restart, Shut Down, Sleep,
   * Force Quit, System Settings and Services.
   * @example await turnover.menu(["Edit", "Copy"]);
   */
  menu(path: string[]): Promise<void>;

  /**
   * Ability: keys. Sends a key press to the plugin's app. PluginPolicy's refusals apply when the request is made:
   * keys that leave the app, TurnOver's own keys, and Paste.
   * @example await turnover.keys("command+k");
   */
  keys(combination: string): Promise<void>;

  /**
   * Ability: clipboard. Puts text on the clipboard. A script can never read the clipboard.
   * @example await turnover.copy("Done");
   */
  copy(text: string): Promise<void>;

  readonly storage: Storage;
}

declare const turnover: Turnover;

/** No ability. Timers: at most 20, none faster than 50 ms. They do not run while none of the plugin's apps is in front. */
declare function setTimeout(handler: () => void, milliseconds?: number): number;
declare function clearTimeout(id: number): void;
declare function setInterval(handler: () => void, milliseconds: number): number;
declare function clearInterval(id: number): void;

/** No ability. Writes to TurnOver's log. */
declare const console: {
  log(...args: unknown[]): void;
  warn(...args: unknown[]): void;
  error(...args: unknown[]): void;
};

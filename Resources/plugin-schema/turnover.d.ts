// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver plugin script interface, version 1, as built (15 Nov 2026). It matches Sources/TurnOverPluginHost/Prelude.swift
// and docs/PLUGIN-SCRIPTS.md. For editors and AI assistants. Scripts are off until the maintainer switches on
// `pluginScripts`.
//
// A script sees the global `turnover`, `console` and the four timers. Nothing else exists: no fetch, no require,
// no file or process objects.
//
// Each member's comment gives the ability it needs, from manifest.json's "abilities". A request without its ability
// rejects with an error that names the ability to add. Every call that asks TurnOver for something returns a promise.

/** The abilities a manifest may list. `read`, `say`, `press`, `focus`, `menu` and `keys` are the data plugins' six. */
type Ability = "read" | "say" | "press" | "focus" | "menu" | "keys" | "edit" | "clipboard";

/**
 * A match, the same object profile.json uses (PLUGIN-GUIDE.md, "Matching elements"). Every field given must agree.
 * Text comparisons ignore case and `*` matches anything. A match TurnOver cannot read rejects.
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
  /** Which of the matches: 1 is first, -1 is last. With `nth`, at most one item comes back. */
  nth?: number;
  /** A list of matches of which one must fit. */
  any?: Match[];
}

/**
 * An item: a copy of what was true when it was made, plus a handle. Reading the fields needs no ability (the
 * ability was needed to get the item). The fields are plain strings, empty when the app gave nothing, never null.
 * TurnOver keeps the last 512 handles it gave this plugin; an older one rejects.
 */
interface Item {
  /** The role in the words a profile.json match uses: the accessibility role without "AX", first letter small, such as "button" or "textField". */
  readonly role: string;
  /** The accessibility role, with its AX prefix, such as "AXButton". */
  readonly axRole: string;
  readonly subrole: string;
  /** The title, or the description when there is no title. At most 1,000 characters. */
  readonly name: string;
  /** At most 8,000 characters. Always "" when `secure` is true. */
  readonly value: string;
  readonly description: string;
  /** The tooltip. */
  readonly help: string;
  /** The app's own identifier. */
  readonly identifier: string;
  /** Words: "focused", "selected", "disabled", "expanded", "collapsed", "checked", "mixed". */
  readonly states: string[];
  /** The title of the window the item is in. */
  readonly window: string;
  /** True for a password field. The plugin sees that it is one, never what is in it, and cannot change it. */
  readonly secure: boolean;

  /** Ability: read. A fresh copy, or null if the item has gone. */
  refresh(): Promise<Item | null>;
  /** Ability: read. The item's parent, or null. A handle the plugin was not given, or one in another app, rejects. */
  parent(): Promise<Item | null>;
  /** Ability: read. The first 200 children. */
  children(): Promise<Item[]>;
  /** Abilities: read and say. TurnOver speaks the item its own way. Resolves with null. Rejects for a password field. */
  read(): Promise<null>;
  /** Ability: press. Resolves with true. Works only while one of the plugin's apps is in front. */
  press(): Promise<boolean>;
  /** Ability: focus. Moves the keyboard focus to the item and resolves with true. Works only while one of the plugin's apps is in front. */
  focus(): Promise<boolean>;
  /**
   * Ability: edit. Changes the item's value and resolves with true. A string or a number. Refused for a password
   * field, and while the Mac hides what is typed or TurnOver cannot tell what has the focus. Works only while one
   * of the plugin's apps is in front.
   */
  setValue(value: string | number): Promise<boolean>;
}

/**
 * What a `focus` or `valueChange` handler receives. The handler must decide before it returns or reaches its first
 * `await`: after that `say` and `silence` throw. The handler has 25 ms to answer. TurnOver sends these events only
 * to a plugin that has the `read` ability, because they carry the item.
 */
interface ReplaceableEvent {
  readonly item: Item;
  /**
   * Replace what TurnOver says for the item. The plan says this needs `say`; the code does not check that when the
   * handler answers (15 Nov 2026), and `turnover-plugin check` warns when `say` is missing.
   */
  say(text: string): void;
  /** Say nothing for the item. The same note about `say` applies. */
  silence(): void;
}

/**
 * What `appFocus`, `appBlur` and `windowChange` handlers receive. There is nothing to replace, and no item. The two
 * members exist so that calling them gives a clear error; they always throw here.
 */
interface NoticeEvent {
  say(text: string): never;
  silence(): never;
}

interface EventMap {
  /** An item in one of the plugin's apps took the focus. It never stops TurnOver's other handling of the focus. */
  focus: ReplaceableEvent;
  /** An item's value changed (never sent for a password field). A value change the script handles stops the chain, as a watch rule does. */
  valueChange: ReplaceableEvent;
  /** One of the plugin's apps came to the front. */
  appFocus: NoticeEvent;
  /** One of the plugin's apps went to the back. */
  appBlur: NoticeEvent;
  /** The window of one of the plugin's apps changed. */
  windowChange: NoticeEvent;
}

/** What a command's handler is given. */
interface CommandContext {
  /** The item with the keyboard focus when the command was chosen, if the plugin has `read`; otherwise null. */
  readonly item: Item | null;
}

interface Storage {
  /**
   * No ability. The plugin's own data, up to 256 KB in all, in a plain file other programs on this Mac can read.
   * A value is anything JSON can hold. `get` gives null when there is nothing under the key; a key is at most 200
   * characters.
   */
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<null>;
  remove(key: string): Promise<null>;
}

interface Turnover {
  /** No ability. This plugin's own manifest fields. */
  readonly plugin: { readonly id: string; readonly name: string; readonly version: string };
  /** No ability. The interface version: 1. */
  readonly api: 1;
  /** No ability. The language TurnOver is using, such as "en". */
  readonly language: string;

  /**
   * No ability to listen. Registers the handler for an event; a second call for the same event replaces the first.
   * An event name that is not in the list throws. Events are never sent for typed characters, caret moves, or
   * anything from an app the plugin did not name.
   * @example turnover.on("focus", (event) => { if (!event.item.name) event.say("Unnamed"); });
   */
  on<K extends keyof EventMap>(name: K, handler: (event: EventMap[K]) => void | Promise<void>): void;

  /**
   * No ability to be called. Registers the handler for a command declared in manifest.json's "commands"; an id that
   * is not declared throws. What the handler does needs its own abilities. A command has 5 seconds to finish.
   * @example turnover.command("readResult", async (context) => { turnover.say("Hello"); });
   */
  command(id: string, handler: (context: CommandContext) => void | Promise<void>): void;

  /**
   * Ability: say. Speaks the text, at most 500 characters (more is cut), and at most 20 things in two seconds. Dropped,
   * with no error, while none of the plugin's apps is in front or a TurnOver approval question is open.
   * @example turnover.say("Saved", { interrupt: false });
   */
  say(text: string, options?: { interrupt?: boolean }): void;

  /**
   * Ability: say. Plays one of TurnOver's own sounds by its file name without ".wav": announcement, blockquote,
   * braille_off, braille_on, browse_mode, comment, done, drill_in, drill_out, edge, empty, focus_mode, graphic,
   * hand_back, heading1 to heading6, landmark, link, list, marked, page_loaded, popup, press, quicknav_off,
   * quicknav_on, secure, spelling, startup, table, take_over, tick, tracking_off, tracking_on. A name TurnOver does
   * not have is logged and nothing plays; it does not reject. Counts toward the same 20 in two seconds as `say`.
   */
  sound(name: string): void;

  /**
   * Ability: read. The item with the keyboard focus, or null.
   * @example const item = await turnover.focused();
   */
  focused(): Promise<Item | null>;

  /**
   * Ability: read. Finds items in the plugin's app (the one in front, else a running one of its apps). `limit` is the
   * most to return; TurnOver never returns more than 50, and a search may take 150 ms. A list of items, empty when
   * nothing matched. Leave the match out to match anything.
   * @example const [save] = await turnover.find({ role: "button", identifier: "Save" }, { limit: 1 });
   */
  find(match?: Match, options?: { limit?: number }): Promise<Item[]>;

  /**
   * Ability: menu. Chooses a command from the app's menus; a path of at most 8 names. Resolves with true. PluginPolicy's
   * refusals apply when the request is made: the Apple menu, a first menu given as a pattern, and Paste, Log Out, Lock
   * Screen, Restart, Shut Down, Sleep, Force Quit, System Settings and Services. Works only while one of the plugin's
   * apps is in front.
   * @example await turnover.menu(["Edit", "Copy"]);
   */
  menu(path: string[]): Promise<boolean>;

  /**
   * Ability: keys. Sends a key press to the plugin's app, written as TurnOver writes keys. Resolves with null.
   * PluginPolicy's refusals apply when the request is made: keys that leave the app, TurnOver's own keys, and Paste.
   * Refused while the Mac hides what is typed (a password field, or a program asked for secure keyboard entry), while
   * a password field has the focus, and when TurnOver cannot tell what has the focus. Works only while one of the
   * plugin's apps is in front.
   * @example await turnover.keys("command+k");
   */
  keys(combination: string): Promise<null>;

  /**
   * Ability: clipboard. Puts text on the clipboard. Resolves with null. A script can never read the clipboard.
   * @example await turnover.copy("Done");
   */
  copy(text: string): Promise<null>;

  readonly storage: Storage;
}

declare const turnover: Turnover;

/**
 * No ability. Timers: at most 20 at once (one more throws), none faster than 50 ms (a shorter delay is made 50). They
 * do not run while none of the plugin's apps is in front. Extra arguments are passed to the callback.
 */
declare function setTimeout(handler: (...args: unknown[]) => void, milliseconds?: number, ...args: unknown[]): number;
declare function clearTimeout(id: number): void;
declare function setInterval(handler: (...args: unknown[]) => void, milliseconds?: number, ...args: unknown[]): number;
declare function clearInterval(id: number): void;

/** No ability. Writes to TurnOver's log, which is how a script shows what it is doing. */
declare const console: {
  log(...args: unknown[]): void;
  warn(...args: unknown[]): void;
  error(...args: unknown[]): void;
};

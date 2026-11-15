// SPDX-License-Identifier: GPL-3.0-or-later
// The script interface (docs/PLUGIN-SCRIPTS-PLAN.md, "The script interface, version 1"), written in JavaScript over
// three native functions: native.send(line) writes one message to TurnOver, native.timer(id, ms, repeats) and
// native.clearTimer(id). The prelude is a function called once with those and the hello's settings; the natives are
// never stored in a global, so the script cannot reach them. It defines `turnover`, `console` and the four timers
// and returns the entry points the host calls: event, command, reply, fire and summary.
enum Prelude {
    static let source = #"""
    (function (native, config) {
      "use strict";
      const globalObject = globalThis;
      // Kept before the script runs, so a script that replaces JSON.stringify later does not change what these send. (Hardening
      // only: TurnOver checks every message it gets, and the host refuses a message with a line break in it.)
      const stringify = JSON.stringify.bind(JSON);
      const parse = JSON.parse.bind(JSON);
      const events = new Map();
      const commands = new Map();
      const declared = new Set(config.commands);
      const pending = new Map();
      const timers = new Map();
      const optionValues = Object.assign({}, config.options || {});
      let nextRequest = 1;
      let nextTimer = 1;

      const LATE = "event.say and event.silence only work before the handler returns. After an await, use turnover.say to add to what TurnOver says.";

      function describe(error) {
        if (error && typeof error === "object" && "message" in error) return String(error.message);
        return String(error);
      }
      function send(message) {
        if (!native.send(stringify(message))) {
          throw new RangeError("That message is larger than " + config.messageBytes + " bytes, so TurnOver refuses it.");
        }
      }
      function log(level, text) {
        try { send({ t: "notify", op: "log", args: { level: level, text: String(text).slice(0, 2000) } }); } catch (e) {}
      }
      function request(op, args) {
        return new Promise(function (resolve, reject) {
          const id = nextRequest++;
          pending.set(id, { resolve: resolve, reject: reject });
          try { send({ t: "request", id: id, op: op, args: args }); }
          catch (error) { pending.delete(id); reject(error); }
        });
      }

      function makeItem(raw) {
        if (raw === null || raw === undefined || typeof raw !== "object") return null;
        const handle = raw.handle;
        const item = {};
        for (const key of Object.keys(raw)) if (key !== "handle") item[key] = raw[key];
        const ask = function (op, extra) { return request(op, Object.assign({ handle: handle }, extra)); };
        Object.defineProperties(item, {
          refresh: { value: function () { return ask("item.refresh").then(makeItem); } },
          parent: { value: function () { return ask("item.parent").then(makeItem); } },
          children: { value: function () { return ask("item.children").then(function (list) { return Array.isArray(list) ? list.map(makeItem) : []; }); } },
          read: { value: function () { return ask("item.read"); } },
          press: { value: function () { return ask("item.press"); } },
          focus: { value: function () { return ask("item.focus"); } },
          setValue: { value: function (value) { return ask("item.setValue", { value: value }); } },
          text: { value: function (options) {
            const unit = options && options.unit !== undefined ? String(options.unit) : "selection";
            if (unit !== "selection" && unit !== "line" && unit !== "all") throw new RangeError('item.text: unit must be "selection", "line" or "all".');
            return ask("item.text", { unit: unit });
          } },
          setCaret: { value: function (offset) { return ask("item.setCaret", { offset: Number(offset) }); } },
          select: { value: function (start, end) { return ask("item.select", { start: Number(start), end: Number(end) }); } }
        });
        return item;
      }

      const turnover = {
        plugin: Object.freeze({ id: config.plugin.id, name: config.plugin.name, version: config.plugin.version }),
        api: config.api,
        language: config.language,
        on: function (name, handler) {
          if (!config.eventNames.includes(name)) throw new Error('Unknown event "' + name + '". The events are ' + config.eventNames.join(", ") + ".");
          if (typeof handler !== "function") throw new TypeError("turnover.on needs a function.");
          events.set(name, handler);
        },
        command: function (id, handler) {
          if (!declared.has(id)) throw new Error('The command "' + id + '" is not declared in manifest.json.');
          if (typeof handler !== "function") throw new TypeError("turnover.command needs a function.");
          commands.set(id, handler);
        },
        say: function (text, options) {
          send({ t: "notify", op: "say", args: { text: String(text), interrupt: !!(options && options.interrupt) } });
        },
        sound: function (name) {
          const wanted = String(name);
          if (!config.sounds.includes(wanted)) throw new Error('TurnOver has no sound called "' + wanted + '".');
          send({ t: "notify", op: "sound", args: { name: wanted } });
        },
        focused: function () { return request("focused", {}).then(makeItem); },
        find: function (match, options) {
          const args = { match: match === undefined ? {} : match };
          if (options && options.limit !== undefined) args.limit = options.limit;
          return request("find", args).then(function (list) { return Array.isArray(list) ? list.map(makeItem) : []; });
        },
        menu: function (path) { return request("menu", { path: path }); },
        keys: function (combination) { return request("keys", { keys: String(combination) }); },
        copy: function (text) { return request("copy", { text: String(text) }); },
        clipboard: function () { return request("clipboard", {}); },
        choose: function (title, items) {
          if (!Array.isArray(items)) throw new TypeError("turnover.choose needs a title and a list of texts.");
          return request("choose", { title: String(title), items: items.map(String) });
        },
        ask: function (prompt) { return request("ask", { prompt: String(prompt) }); },
        tone: function (hertz, milliseconds) {
          const pitch = Number(hertz), length = Number(milliseconds);
          if (!(pitch >= config.toneHertz[0] && pitch <= config.toneHertz[1])) throw new RangeError("A tone's pitch is " + config.toneHertz[0] + " to " + config.toneHertz[1] + " hertz.");
          if (!(length >= config.toneMilliseconds[0] && length <= config.toneMilliseconds[1])) throw new RangeError("A tone lasts " + config.toneMilliseconds[0] + " to " + config.toneMilliseconds[1] + " milliseconds.");
          send({ t: "notify", op: "tone", args: { hertz: pitch, milliseconds: length } });
        },
        options: Object.freeze({
          get: function (id) {
            const wanted = String(id);
            return Object.prototype.hasOwnProperty.call(optionValues, wanted) ? optionValues[wanted] : null;
          }
        }),
        storage: Object.freeze({
          get: function (key) { return request("storage.get", { key: String(key) }); },
          set: function (key, value) { return request("storage.set", { key: String(key), value: value }); },
          remove: function (key) { return request("storage.remove", { key: String(key) }); }
        })
      };
      Object.freeze(turnover);

      function format(args) { return Array.prototype.map.call(args, function (a) { return typeof a === "string" ? a : (function () { try { return JSON.stringify(a); } catch (e) { return String(a); } })(); }).join(" "); }
      const consoleObject = Object.freeze({
        log: function () { log("info", format(arguments)); },
        warn: function () { log("warning", format(arguments)); },
        error: function () { log("error", format(arguments)); }
      });

      function addTimer(callback, delay, repeats, extra) {
        if (typeof callback !== "function") throw new TypeError("A timer needs a function.");
        if (timers.size >= config.timers) throw new Error("A script can have at most " + config.timers + " timers at once.");
        let ms = Number(delay);
        if (!(ms >= config.minimumTimerMilliseconds)) ms = config.minimumTimerMilliseconds;
        const id = nextTimer++;
        timers.set(id, { callback: callback, extra: extra, repeats: repeats });
        native.timer(id, ms, repeats);
        return id;
      }
      function clearTimer(id) { if (timers.delete(id)) native.clearTimer(id); }

      function define(name, value) {
        Object.defineProperty(globalObject, name, { value: value, writable: true, configurable: true, enumerable: false });
      }
      define("turnover", turnover);
      define("console", consoleObject);
      define("setTimeout", function (callback, delay) { return addTimer(callback, delay, false, Array.prototype.slice.call(arguments, 2)); });
      define("setInterval", function (callback, delay) { return addTimer(callback, delay, true, Array.prototype.slice.call(arguments, 2)); });
      define("clearTimeout", clearTimer);
      define("clearInterval", clearTimer);

      function makeEvent(name, raw) {
        const state = { open: true, say: null };
        const event = {};
        if (raw.item) event.item = makeItem(raw.item);
        if (raw.data && typeof raw.data === "object") {
          if (name === "optionsChange") { event.id = String(raw.data.id); event.value = raw.data.value; }
          else if (name === "speech") { event.text = String(raw.data.text); }
        }
        const replaceable = config.replaceableEvents.includes(name);
        Object.defineProperties(event, {
          say: { value: function (text) {
            if (!state.open) throw new Error(LATE);
            if (!replaceable) throw new Error("There is nothing to replace for " + name + ". Use turnover.say to speak.");
            state.say = String(text);
          } },
          silence: { value: function () {
            if (!state.open) throw new Error(LATE);
            if (!replaceable) throw new Error("There is nothing to silence for " + name + ".");
            state.say = "";
          } }
        });
        return { event: event, state: state };
      }

      const entry = {
        event: function (line) {
          const message = parse(line);
          const handler = events.get(message.name);
          const reply = { t: "eventDone", id: message.id, handled: false };
          if (handler) {
            const made = makeEvent(message.name, message);
            try {
              const result = handler(made.event);
              if (result && typeof result.then === "function") result.then(undefined, function (e) { log("error", "The " + message.name + " handler failed: " + describe(e)); });
              if (made.state.say !== null) { reply.handled = true; reply.say = made.state.say; }
            } catch (error) {
              log("error", "The " + message.name + " handler failed: " + describe(error));
            }
            made.state.open = false;
          }
          send(reply);
        },
        command: function (line) {
          const message = parse(line);
          const handler = commands.get(message.command);
          const finish = function (error) { send({ t: "commandDone", id: message.id, error: error }); };
          if (!handler) { finish('The script has no handler for the command "' + message.command + '".'); return; }
          let result;
          try { result = handler({ item: message.item ? makeItem(message.item) : null }); }
          catch (error) { finish(describe(error)); return; }
          Promise.resolve(result).then(function () { finish(null); }, function (error) { finish(describe(error)); });
        },
        options: function (line) {
          const message = parse(line);
          if (!message.values || typeof message.values !== "object") return;
          for (const key of Object.keys(optionValues)) delete optionValues[key];
          Object.assign(optionValues, message.values);
        },
        reply: function (line) {
          const message = parse(line);
          const waiting = pending.get(message.id);
          if (!waiting) return;
          pending.delete(message.id);
          if (message.ok) waiting.resolve(message.value);
          else waiting.reject(new Error(String(message.error)));
        },
        fire: function (id) {
          const timer = timers.get(id);
          if (!timer) return;
          if (!timer.repeats) timers.delete(id);
          try { timer.callback.apply(undefined, timer.extra); }
          catch (error) { log("error", "A timer failed: " + describe(error)); }
        },
        summary: function () {
          return stringify({ events: Array.from(events.keys()), commands: Array.from(commands.keys()) });
        }
      };
      return entry;
    })
    """#
}

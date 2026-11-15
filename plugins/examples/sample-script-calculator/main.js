// main.js: the script for "Calculator, scripted".
//
// The script runs in a sandbox, apart from TurnOver. It cannot use the internet, files or other programs. It can only
// ask TurnOver, through `turnover`, for what manifest.json's "abilities" lists ("read" and "say" here), and TurnOver
// checks every request. Try it without Calculator: `turnover-plugin test <this folder>` runs tests/script/*.json.

// An event. TurnOver tells the script when the focus lands on an item. The words are decided before the handler
// returns, from the item it was given: event.say replaces what TurnOver would say for this item, event.silence says
// nothing, and doing neither leaves TurnOver to read the item as usual. (Both need the "say" ability.)
turnover.on("focus", function (event) {
  const item = event.item;
  if (item.role === "button" && item.name === "" && item.identifier === "clear") {
    event.say("Clear, button");
  }
});

// A command. "readResult" is declared in manifest.json, with its key; the script is only told it was chosen.
// The handler may be `async`: `await` waits for TurnOver's answer (this one needs "read").
turnover.command("readResult", async function (context) {
  // turnover.find takes the same match object as profile.json's rules, and answers with a list of items, empty if
  // nothing matched. Each item is a copy of what was true a moment ago.
  const found = await turnover.find({ role: "text", identifier: "result" }, { limit: 1 });
  if (found.length === 0) {
    turnover.say("There is no result to read");
    return;
  }
  // turnover.say adds to what TurnOver says; it does not replace anything. (It needs "say".)
  turnover.say(String(found[0].value));
});

// main.js: the script for "Button chooser, scripted". It works in every app (manifest.json: apps is ["*"] and the
// "everywhere" ability), so TurnOver starts it as it starts reading and never pauses it when you change app. Every
// request is still judged against the app really in front, so it does nothing in a password dialog, and in a terminal
// or browser it could only read and speak (here, pressing a button there is refused).
//
// The person sets the three options in TurnOver's Plugins menu; turnover.options.get gives their value now.
// Try it without an app: `turnover-plugin test <this folder>` runs tests/script/*.json.

// The command: find the buttons of the window the focus is in, offer them in TurnOver's own list, press the one chosen.
turnover.command("chooseButton", async function (context) {
  const includeDisabled = turnover.options.get("includeDisabled");
  const limit = turnover.options.get("limit");
  // The item with the focus when the command was chosen (the "read" ability gives it); its window is the one in front.
  const window = context.item ? context.item.window : "";

  const found = await turnover.find({ role: "button" }, { limit: limit });
  const buttons = found.filter(function (button) {
    if (window !== "" && button.window !== window) return false;
    return includeDisabled || !(button.states || []).includes("disabled");
  });
  if (buttons.length === 0) {
    turnover.say("No buttons to list here");
    return;
  }

  // The list shows words, so each button needs a name, and two with the same name need telling apart.
  const labels = [];
  const byLabel = new Map();
  buttons.forEach(function (button) {
    const base = button.name || button.description || button.identifier || "Unnamed button";
    let label = base;
    for (let n = 2; byLabel.has(label); n++) label = base + " (" + n + ")";
    byLabel.set(label, button);
    labels.push(label);
  });

  // choose resolves with the text of the item the person chose, or null if they dismissed the list.
  const chosen = await turnover.choose(window === "" ? "Buttons in this window" : "Buttons in " + window, labels);
  if (chosen === null) return;
  await byLabel.get(chosen).press();
  if (turnover.options.get("announce")) turnover.say("Pressed " + chosen);
});

// An option changed in the menu. (turnover.options.get is already current; this is for a script that must act at once.)
turnover.on("optionsChange", function (event) {
  console.log("The option " + event.id + " is now " + event.value);
});

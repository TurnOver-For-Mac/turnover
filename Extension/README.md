# TurnOver Page Reader: passive page shaping

This restores the useful page-shaping part of the 28 October 2026 Safari prototype, with a smaller passive scope.
Safari still supplies TurnOver and VoiceOver with the page through its accessibility tree. The extension does not
build or transmit a second reading tree, retain page coordinates or choose a reading position.

## What it changes

On sites Safari permits it to access, the content script supplies conservative missing accessibility semantics:

- A proven redundant unnamed icon can be hidden inside a control that keeps real text or an author-supplied name.
  Standalone images, sole-action icons, literal repeated words and brand spellings stay unchanged.
- An anonymous noninteractive spinner can be named Loading. A recognisable noninteractive visual progress track can
  receive a percentage. Native controls and containers with focus, editing or click behavior keep their semantics.

Explicit site labels, roles, focus order and live-region settings remain authoritative. The script remembers the
exact attributes it supplied and stops managing an attribute if the site changes it. Hidden icons are reassessed
when content changes; meaningful content or loss of the other control name releases the owned hide. It does not turn
guessed divs into buttons, add keyboard handlers, quiet alerts or generate Loaded announcements. Text/candidate limits leave
incomplete repairs alone. A pass shares 4,000 work units across text/shape walks and ancestor protection checks;
exhaustion preserves remaining semantics. Browser selector/layout calls cannot be preempted, so this is not a hard
time limit or complete accessibility repair for a large or unusual page.

## Privacy and actions

There is no background script, messaging permission, network request, native-message call, page-tree API or capture
switch in this version. The native Safari bundle needs no app-group socket. Its separately implemented handler can
answer fixed status metadata only.

No field value is read. Password types are protected before ARIA roles; password/one-time-code autocomplete tokens
and CSS text masking also exclude a field and its descendants from text inspection and repairs. This protects
recognised sensitive fields, rather than promising to identify every application-defined secret representation.
The extension never clicks cookie banners, changes focus, sends keys, submits forms or writes field values.

The manifest requests page access for the content script, subject to Safari's own site-access permissions. Allowing
access changes that page's accessibility attributes, so test with both screen readers on public sample pages.
Disabling the extension prevents further repairs; reload a page to discard already-applied DOM attributes.

## Regression checks

`tests/passive-tests.js` exposes `runPassiveExtensionTests(source)`, returning named pass/fail records. It evaluates
the actual `content.js` with synthetic DOM globals and throwing protected-field getters. It runs with the system
JavaScriptCore test bridge; Node is optional and is not a build dependency.

For an optional local run:

```sh
node Extension/tests/run-node.cjs
```

The old stress-site checklist covered tree navigation and automatic actions outside this passive scope and is not
shipped here. These synthetic checks establish privacy/passivity and repair behaviour, not Safari's extension
registration or how speech sounds. The full signed app build and Oliver's local trial are required before publishing.

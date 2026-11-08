#!/usr/bin/env python3
"""Run real tap callback bodies with OS posting, speech and main-thread decisions isolated.
Requires a matching build of TurnOverCore. Never starts a tap or a reader.
"""
from pathlib import Path
import subprocess, tempfile, os, shutil
repo = Path(__file__).resolve().parents[2]
build = Path.home() / 'Library/Developer/TurnOver/build'
product = build / 'out/Products' / ('Debug' if '--tsan' in os.sys.argv else 'Release')
probe_build = build.parent / 'keyboard-adapter-tests'
probe_build.mkdir(exist_ok=True)
def body(s, marker, replacement):
    a=s.index('{',s.index(marker)); i=a+1; depth=1
    while depth:
        depth+=(s[i]=='{')-(s[i]=='}'); i+=1
    return s[:a]+'{\n'+replacement+'\n}'+s[i:]
with tempfile.TemporaryDirectory(prefix='turnover-adapter-tests-') as tmp:
    p=Path(tmp)
    windows=(repo/'Sources/TurnOver/WindowsKeys.swift').read_text()
    windows=body(windows,'static func post(_ t:', 'Audit.posts.value.append(t.code)')
    windows=body(windows,'static func say(_ text:', 'Audit.messages.value.append(text)')
    windows=windows.replace('private func handle(_ type:', 'func handle(_ type:')
    windows=windows.replace('static let shared = WindowsKeyLayer()', '''static let shared = WindowsKeyLayer()
    func auditPrepare() {
        lifecycle.lock.lock()
        let g = lifecycle.unsafeValue.session.requestStart()
        _ = lifecycle.unsafeValue.session.beginWorker()
        lifecycle.lock.unlock()
        layer = Layer(g)
    }
    func auditPassNext() { passNext = true }
''')
    windows=windows.replace('static var frontApp: FrontApp { foreground.value }', 'static var frontApp: FrontApp { get { foreground.value } set { foreground.value = newValue } }')
    p.joinpath('WindowsKeys.swift').write_text(windows)
    handler=(repo/'Sources/TurnOver/KeyboardHandler.swift').read_text()
    handler=body(handler,'    init()', '')
    handler=handler.replace('private func tapEvent(_ type:', 'func tapEvent(_ type:')
    handler=handler.replace('    static let marker:', '''    func auditPrepare() {
        lifecycle.lock.lock()
        let g = lifecycle.unsafeValue.session.requestStart()
        _ = lifecycle.unsafeValue.session.beginWorker()
        lifecycle.lock.unlock()
        layer = Layer(generation: g)
    }
    func auditTearDown() { if let layer { tearDown(layer) } }
    static let marker:''')
    # The branches and routing are original; all external event delivery is a recording sink.
    for name, source in [('KeyboardHandler.swift',handler), ('KeyboardInsert.swift',(repo/'Sources/TurnOver/KeyboardInsert.swift').read_text())]:
        source=source.replace('event.postToPid(direct)', 'Audit.record(event, direct)')
        source=source.replace('event.postToPid(pid)', 'Audit.record(event, pid)')
        source=source.replace('replay.event.postToPid(replay.pid)', 'Audit.record(replay.event, replay.pid)').replace('event.postToPid(release.pid)', 'Audit.record(event, release.pid)')
        p.joinpath(name).write_text(source)
    application=(repo/'Sources/TurnOver/KeyboardApplication.swift').read_text()
    application=application.replace('event.postToPid(pid)', 'Audit.record(event, pid)').replace('event.postToPid(owner)', 'Audit.record(event, owner)').replace('event.postToPid(destination)', 'Audit.record(event, destination)')
    application=application.replace('keypadRouter.passedToApplication(code: code)', 'if Audit.releaseAfterPublication.value { Audit.releaseAfterPublication.value=false; let up=event.copy()!; up.type = .keyUp; _=KeypadApplicationDelivery.continueEvent(owner:ObjectIdentifier(self),.keyUp,up) }; keypadRouter.passedToApplication(code: code)')
    p.joinpath('KeyboardApplication.swift').write_text(application)
    delivery=(repo/'Sources/TurnOver/KeypadApplicationDelivery.swift').read_text().replace('event.postToPid(pid)', 'Audit.record(event, pid)').replace('event.postToPid(destination)', 'Audit.record(event, destination)').replace('event.postToPid(release.pid)', 'Audit.record(event, release.pid)').replace('item.event.postToPid(item.pid)', 'Audit.record(item.event, item.pid)')
    p.joinpath('KeypadApplicationDelivery.swift').write_text(delivery)
    recovery=repo/'Sources/TurnOver/KeyboardRecovery.swift'
    if recovery.exists():
        s=recovery.read_text().replace('replay.event.postToPid(replay.pid)', 'Audit.record(replay.event, replay.pid)').replace('event.postToPid(release.pid)', 'Audit.record(event, release.pid)')
        p.joinpath('KeyboardRecovery.swift').write_text(s)
    p.joinpath('Stubs.swift').write_text('''import Foundation
import AppKit
import CoreGraphics
import TurnOverCore
nonisolated enum Audit {
 struct Delivery: Sendable { var code: Int64; var type: CGEventType; var pid: Int32 }
 static let deliveries = Locked<[Delivery]>([])
 static let posts = Locked<[Int64]>([])
 static let messages = Locked<[String]>([])
 static let asleep = Locked(false)
 static let help = Locked(false)
 static let calls = Locked(0)
 static let commands = Locked<[String]>([])
 static let releaseAfterPublication = Locked(false)
 static func record(_ e: CGEvent, _ pid: Int32) { deliveries.value.append(Delivery(code:e.getIntegerValueField(.keyboardEventKeycode), type:e.type, pid:pid)) }
}
nonisolated enum HandOver {
 struct Shortcut { let keyCode: UInt16 = 999; let flags: CGEventFlags = [] }
 static func toggleShortcut() -> Shortcut { Shortcut() }
}
nonisolated enum Coexist { static var on: Bool { false } }
nonisolated enum AXHandler {
 static let anyMenuOpen = Locked(false)
}
// Probe callbacks are invoked synchronously on main; execute main-actor sinks there.
nonisolated func onMain(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) { MainActor.assumeIsolated(body) }
@MainActor final class TurnOverMenu {
 static let shared = TurnOverMenu()
 nonisolated static let anyOpen = Locked(false)
 var isOpen: Bool { false }
 func openSettings() { Audit.commands.value.append("settings") }
}
nonisolated enum InputManager {
 static var isAsleep: Bool { Audit.asleep.value }
 static func isAsleep(bundle: String) -> Bool { Audit.asleep.value }
 static var isCapturing: Bool { false }
 static var isInputHelpActive: Bool { Audit.help.value }
 static var passNextKey: Bool { get { pass.value } set { pass.value = newValue } }
 static let pass = Locked(false)
 static let direct = Locked<Int32?>(nil)
 static var directPid: Int32? { direct.value }
 static var turnOverKeyLocked: Bool { false }
 @MainActor static func handleInputHelp(_ g: KeyboardGesture, script: Script?) {}
}
nonisolated enum ScriptHandler {
 enum KeyDecision { case taken, passed, deferred }
 static func askMain(_ g: KeyboardGesture) -> KeyDecision {
  Audit.calls.value += 1
  if g.keyCode == 6 && g.modifiers == [.turnover,.shift] { Audit.asleep.value = false; return .taken }
  if InputManager.passNextKey { InputManager.passNextKey = false; return .passed }
  return Audit.help.value || g.modifiers.contains(.turnover) ? .taken : .passed
 }
 static func mainHasScript(for g: KeyboardGesture) -> Bool? { false }
 @MainActor static func findScript(named: String) -> Script? { nil }
 @MainActor static func queueScript(_ s: Script, gesture: KeyboardGesture) {}
}
nonisolated enum Keypad {
 static let codes = TurnOverCore.Keypad.codes
 static func toggleWindows(announce: (String) -> Void = { _ in }) {
  MainActor.assumeIsolated { config.keyboard.keypadCommands.toggle(); KeySettings.refresh() }
 }
 @MainActor static func run(_ g: KeyboardGesture, windows: Bool, action: String? = nil) { Audit.commands.value.append(action ?? "") }
}
@MainActor final class MenuAnywhere {
 static let shared = MenuAnywhere()
 func open() {}
 func recognize() {}
 func recognizeInterface() {}
}
extension KeyboardHandler {
 nonisolated func clearLeftoverModifiers(before: String) {}
 nonisolated static func post(_ g: KeyboardGesture) {}
 nonisolated static func postTyped(_ g: KeyboardGesture) {}
 nonisolated static func postChord(_ codes: [Int64]) {}
 nonisolated static func postText(_ text: String) {}
}
''')
    p.joinpath('main.swift').write_text('''import Foundation
import CoreGraphics
import TurnOverCore
var failed = 0
var checked = 0
@MainActor func check(_ condition: Bool, _ name: String) { checked += 1; if !condition { failed += 1; print("FAIL " + name) } }
func event(_ type: CGEventType, _ code: Int64, repeatKey: Bool = false, flags: CGEventFlags = []) -> CGEvent {
 let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: type == .keyDown)!
 e.type=type; e.flags=flags; e.setIntegerValueField(.keyboardEventAutorepeat,value:repeatKey ? 1 : 0); return e
}
@MainActor func settings(numbers: Bool = false) {
 KeypadApplicationDelivery.state.value = KeypadApplicationDelivery.State()
 config.general.keyboardStyle="jaws"; config.general.turnOverKey="insert"
 config.keyboard.layout="desktop"; config.keyboard.keypadCommands = !numbers; KeySettings.refresh()
 Audit.asleep.value=false; Audit.help.value=false; Audit.deliveries.value=[]; Audit.posts.value=[]
 InputManager.direct.value=nil; InputManager.passNextKey=false; KeyboardHandler.bypass=false; KeyboardHandler.redirectPid=nil
 WindowsRemap.frontApp = WindowsRemap.FrontApp(bundle:"audit",pid:123)
}
for main in [false,true] {
 settings(numbers:true)
 let primary=KeyboardHandler(); primary.auditPrepare()
 let windows=WindowsKeyLayer(); windows.auditPrepare()
 func feed(_ t: CGEventType, _ c: Int64, _ repeatKey: Bool = false) -> Bool {
  let e=event(t,c,repeatKey:repeatKey)
  return (main ? primary.tapEvent(t,e) : windows.handle(t,e)) != nil
 }
 check(feed(.keyDown,91), "R1 initial application down \\(main)")
 config.keyboard.keypadCommands=true; KeySettings.refresh()
 _=feed(.keyDown,82)
 check(feed(.keyDown,91,true), "R1 application repeat after Insert \\(main)")
 check(feed(.keyUp,91), "R1 paired application up \\(main)")
 _=feed(.keyUp,82)
 Audit.posts.value=[]; Audit.commands.value=[]
 _=feed(.keyDown,82)
 _=feed(.keyDown,91)
 check(main ? Audit.commands.value == ["run:reportCurrentLine"] : Audit.posts.value == [37], "R1 next fresh press resolves its command \(main)")
 _=feed(.keyUp,91); _=feed(.keyUp,82)
}
for delivery in ["direct","redirect"] {
 settings(numbers:true)
 let h=KeyboardHandler(); h.auditPrepare()
 if delivery=="direct" { InputManager.direct.value=123 } else { KeyboardHandler.redirectPid=123 }
 _=h.tapEvent(.keyDown,event(.keyDown,91))
 InputManager.direct.value=nil; KeyboardHandler.redirectPid=nil
 WindowsRemap.frontApp=WindowsRemap.FrontApp(bundle:"other",pid:456)
 config.keyboard.keypadCommands=true; KeySettings.refresh()
 _=h.tapEvent(.keyDown,event(.keyDown,82))
 Audit.commands.value=[]
 _=h.tapEvent(.keyDown,event(.keyDown,91,repeatKey:true))
 _=h.tapEvent(.keyUp,event(.keyUp,91))
 check(Audit.deliveries.value.filter { $0.code==91 && $0.pid==123 }.map(\\.type)==[.keyDown,.keyDown,.keyUp],"R1 " + delivery + " repeat and up retain original PID")
 check(Audit.commands.value.isEmpty,"R1 " + delivery + " repeat cannot become command")
 _=h.tapEvent(.keyUp,event(.keyUp,82))
}
for delivery in ["direct","redirect"] {
 settings(numbers:true)
 let h=KeyboardHandler(); h.auditPrepare()
 if delivery=="direct" { InputManager.direct.value=123 } else { KeyboardHandler.redirectPid=123 }
 _=h.tapEvent(.keyDown,event(.keyDown,91))
 h.auditTearDown()
 InputManager.direct.value=nil; KeyboardHandler.redirectPid=nil
 WindowsRemap.frontApp=WindowsRemap.FrontApp(bundle:"other",pid:456)
 let replacement=WindowsKeyLayer(); replacement.auditPrepare()
 check(replacement.handle(.keyDown,event(.keyDown,91,repeatKey:true)) == nil,"R1 " + delivery + " late repeat suppressed after teardown")
 check(replacement.handle(.keyUp,event(.keyUp,91)) == nil,"R1 " + delivery + " late up suppressed after teardown")
 check(Audit.deliveries.value.filter { $0.code==91 && $0.pid==123 }.map(\\.type)==[.keyDown,.keyUp],"R1 " + delivery + " teardown completes original PID")
}
for teardownFirst in [false,true] {
 settings(numbers:true)
 let h=KeyboardHandler(); h.auditPrepare()
 check(h.tapEvent(.keyDown,event(.keyDown,91)) != nil,"R1 session down passes")
 if teardownFirst { h.auditTearDown() }
 config.keyboard.keypadCommands=true; KeySettings.refresh()
 let replacement=WindowsKeyLayer(); replacement.auditPrepare()
 _=replacement.handle(.keyDown,event(.keyDown,82))
 check(replacement.handle(.keyDown,event(.keyDown,91,repeatKey:true)) != nil,"R1 session repeat survives reader replacement")
 check(replacement.handle(.keyUp,event(.keyUp,91)) != nil,"R1 session release survives reader replacement")
 _=replacement.handle(.keyUp,event(.keyUp,82))
 if !teardownFirst { h.auditTearDown() }
}
settings(numbers:true)
let oldWindows=WindowsKeyLayer(); oldWindows.auditPrepare()
_=oldWindows.handle(.keyDown,event(.keyDown,91))
config.keyboard.keypadCommands=true; KeySettings.refresh()
let newPrimary=KeyboardHandler(); newPrimary.auditPrepare()
_=newPrimary.tapEvent(.keyDown,event(.keyDown,82))
check(newPrimary.tapEvent(.keyDown,event(.keyDown,91,repeatKey:true)) != nil,"R1 session repeat survives Windows-to-primary replacement")
check(newPrimary.tapEvent(.keyUp,event(.keyUp,91)) != nil,"R1 session up survives Windows-to-primary replacement")
_=newPrimary.tapEvent(.keyUp,event(.keyUp,82))
settings(numbers:true)
let firstOwner=KeyboardHandler(); firstOwner.auditPrepare()
let secondOwner=KeyboardHandler(); secondOwner.auditPrepare()
InputManager.direct.value=123
_=firstOwner.tapEvent(.keyDown,event(.keyDown,91))
InputManager.direct.value=456
_=secondOwner.tapEvent(.keyDown,event(.keyDown,92))
firstOwner.auditTearDown()
_=secondOwner.tapEvent(.keyDown,event(.keyDown,92,repeatKey:true))
_=secondOwner.tapEvent(.keyUp,event(.keyUp,92))
check(Audit.deliveries.value.filter { $0.code==91 && $0.pid==123 }.map(\\.type)==[.keyDown,.keyUp],"R1 retiring owner closes only its own press")
check(Audit.deliveries.value.filter { $0.code==92 && $0.pid==456 }.map(\\.type)==[.keyDown,.keyDown,.keyUp],"R1 retiring owner preserves replacement press")
secondOwner.auditTearDown()
settings(numbers:true)
let ordinary=KeyboardHandler(); ordinary.auditPrepare()
_=ordinary.tapEvent(.keyDown,event(.keyDown,91))
KeyboardHandler.redirectPid=456
check(ordinary.tapEvent(.keyDown,event(.keyDown,91,repeatKey:true)) != nil,"R1 session repeat must not adopt later redirect")
check(ordinary.tapEvent(.keyUp,event(.keyUp,91)) != nil,"R1 session up must not adopt later redirect")
check(Audit.deliveries.value.isEmpty,"R1 no orphan redirected continuation")
for sleepingState in ["pending","forwarded","wake"] {
 settings(); Audit.asleep.value=true
 let old=KeyboardHandler(); old.auditPrepare()
 _=old.tapEvent(.keyDown,event(.keyDown,82))
 if sleepingState=="forwarded" { _=old.tapEvent(.keyDown,event(.keyDown,0)) }
 if sleepingState=="wake" { _=old.tapEvent(.keyDown,event(.keyDown,6,flags:.maskShift)) }
 old.stop()
 let replacement=WindowsKeyLayer(); replacement.auditPrepare()
 let codes: [Int64] = sleepingState=="forwarded" ? [82,0] : sleepingState=="wake" ? [82,6] : [82]
 for code in codes {
  for type in [CGEventType.keyDown,.keyUp] {
   let e=event(type,code,repeatKey:type == .keyDown)
   let next=replacement.handle(type,e)
   let final=next == nil ? nil : old.tapEvent(type,e)
   check(final == nil,"R3 overlapping reader preserves " + sleepingState + " ownership")
  }
 }
 old.auditTearDown()
 if sleepingState=="wake" { check(Audit.deliveries.value.isEmpty,"R3 overlapping wake never types") }
 else {
  for code in codes {
   check(Audit.deliveries.value.filter { $0.code==code && $0.pid==123 }.map(\\.type)==[.keyDown,.keyDown,.keyUp],"R3 overlapping " + sleepingState + " retains complete original-PID stream")
  }
 }
}
for type in [CGEventType.keyDown,.keyUp] {
 settings(); Audit.asleep.value=true
 let old=KeyboardHandler(); old.auditPrepare()
 _=old.tapEvent(.keyDown,event(.keyDown,82)); old.stop()
 let replacement=WindowsKeyLayer(); replacement.auditPrepare()
 let passed=replacement.handle(type,event(type,82,repeatKey:type == .keyDown))
 old.auditTearDown() // the old tap disappears before any downstream callback can happen
 check(passed == nil,"R3 replacement cannot defer to a disappearing tap")
 let expected: [CGEventType] = type == .keyDown ? [.keyDown,.keyDown,.keyUp] : [.keyDown,.keyUp]
 check(Audit.deliveries.value.filter { $0.code==82 && $0.pid==123 }.map(\\.type)==expected,"R3 replacement resolves sleeping input before old tap disappears")
}
settings()
Audit.asleep.value=true
let sleeping=KeyboardHandler(); sleeping.auditPrepare()
_=sleeping.tapEvent(.keyDown,event(.keyDown,82))
_=sleeping.tapEvent(.keyDown,event(.keyDown,82,repeatKey:true))
_=sleeping.tapEvent(.keyDown,event(.keyDown,6,flags:.maskShift))
check(!Audit.asleep.value,"R2 repeat then wake through primary adapter")
check(Audit.deliveries.value.isEmpty,"R2 wake must not type zero")
for transition in ["bypass","direct","stop","stop-request"] {
 settings(); Audit.asleep.value=true
 let h=KeyboardHandler(); h.auditPrepare()
 _=h.tapEvent(.keyDown,event(.keyDown,82))
 if transition=="bypass" { KeyboardHandler.bypass=true }
 if transition=="direct" { InputManager.direct.value=456; WindowsRemap.frontApp=WindowsRemap.FrontApp(bundle:"direct",pid:456) }
 if transition=="stop" { h.auditTearDown() }
 if transition=="stop-request" { h.stop() }
 let release=h.tapEvent(.keyUp,event(.keyUp,82))
 if transition=="stop-request" {
  check(release == nil,"R3 retiring callback retains pending release")
  h.auditTearDown()
  check(!KeypadApplicationDelivery.state.value.retired.contains(82),"R3 real release prevents stale handover quarantine")
 }
 let d=Audit.deliveries.value.filter { $0.code==82 && $0.pid==123 }
 check(d.map(\\.type)==[.keyDown,.keyUp],"R3 original PID paired across " + transition)
 check(!Audit.deliveries.value.contains { $0.code==82 && $0.pid==456 },"R3 no orphan up to direct app")
}
settings(numbers:true)
let publishing=KeyboardHandler(); publishing.auditPrepare()
InputManager.direct.value=123; Audit.releaseAfterPublication.value=true
_=publishing.tapEvent(.keyDown,event(.keyDown,91))
check(Audit.deliveries.value.map(\\.type)==[.keyDown,.keyUp],"R1 initial publication and explicit down cannot be separated by replacement up")
for _ in 0..<100 {
 settings()
 let h=KeyboardHandler(); let owner=ObjectIdentifier(h)
 let down=event(.keyDown,91)
 KeypadApplicationDelivery.deliverDown(owner:owner,code:91,flags:[],event:down,pid:123)
 DispatchQueue.concurrentPerform(iterations:2) { worker in
  if worker==0 {
   for _ in 0..<20 { _=KeypadApplicationDelivery.continueEvent(owner:owner,.keyDown,event(.keyDown,91,repeatKey:true)) }
  } else { KeypadApplicationDelivery.finish(owner:owner) }
 }
 let types=Audit.deliveries.value.map(\\.type)
 check(types.first == .keyDown && types.last == .keyUp && types.filter { $0 == .keyUp }.count==1,"R1 concurrent retirement cannot be overtaken by repeats")
 settings()
 let foreign=WindowsKeyLayer(); let foreignOwner=ObjectIdentifier(foreign)
 _=KeypadApplicationDelivery.routeSleeping(owner:owner,type:.keyDown,event:event(.keyDown,82),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 DispatchQueue.concurrentPerform(iterations:2) { worker in
  if worker==0 { _=KeypadApplicationDelivery.continueEvent(owner:foreignOwner,.keyUp,event(.keyUp,82)) }
  else { KeypadApplicationDelivery.finishSleeping(owner:owner) }
 }
 check(Audit.deliveries.value.map(\\.type)==[.keyDown,.keyUp],"R3 concurrent sleeping release/retirement completes exactly once")
}
print("Adapter assertions: \\(checked); failures: \\(failed)")
exit(failed == 0 ? 0 : 1)
''')
    args=['swiftc','-sdk','/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk','-swift-version','6','-I',str(product),'-L',str(product),'-lTurnOverCore','-Xlinker','-rpath','-Xlinker',str(product)]
    for module in ['TurnOverObjC','TurnOverBraille']:
        args += ['-Xcc','-fmodule-map-file='+str(build/'out/Intermediates.noindex/GeneratedModuleMaps'/f'{module}.modulemap')]
    if '--tsan' in os.sys.argv: args += ['-sanitize=thread']
    binary=probe_build/'adapters'
    try:
        subprocess.run(args+list(map(str,p.glob('*.swift')))+['-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
    finally:
        binary.unlink(missing_ok=True)
        probe_build.rmdir()

// SPDX-License-Identifier: GPL-3.0-or-later
// Included in the adapter probe main file; never starts a live reader.
// Maintainer review: recover from missed physical releases in either adapter.
for main in [false,true] {
 for code in [Int64(82),114] {
  settings()
  let h=KeyboardHandler(); h.auditPrepare()
  let w=WindowsKeyLayer(); w.auditPrepare()
  func send(_ type: CGEventType,_ code: Int64,_ repeatKey: Bool=false) -> Bool {
   let e=event(type,code,repeatKey:repeatKey)
   return (main ? h.tapEvent(type,e) : w.handle(type,e)) != nil
  }
  _=send(.keyDown,code)
  Audit.hardwareDown.value=[]
  check(send(.keyDown,0),"M1 missed Insert release must not capture laptop A")
 }
}
for reverse in [false,true] {
 for insertCode in [Int64(82),114] {
 settings()
 let h=KeyboardHandler(); h.auditPrepare()
 let w=WindowsKeyLayer(); w.auditPrepare()
 if reverse { _=w.handle(.keyDown,event(.keyDown,insertCode)); w.stop() }
 else { _=h.tapEvent(.keyDown,event(.keyDown,insertCode)); h.auditTearDown() }
 let repeatEvent=event(.keyDown,insertCode,repeatKey:true)
 check((reverse ? h.tapEvent(.keyDown,repeatEvent) : w.handle(.keyDown,repeatEvent)) == nil,"M2 held Insert repeat cannot leak across handover")
 Audit.commands.value=[]; Audit.posts.value=[]
 let line=event(.keyDown,91)
 _ = reverse ? h.tapEvent(.keyDown,line) : w.handle(.keyDown,line)
 check(reverse ? Audit.commands.value == ["run:reportCurrentLine"] : Audit.posts.value == [37],"M2 held Insert remains modifier in replacement")
 let up=event(.keyUp,insertCode)
 check((reverse ? h.tapEvent(.keyUp,up) : w.handle(.keyUp,up)) == nil,"M2 replacement consumes Insert release")
}
}
settings()
do {
 var router=SleepInsertRouter()
 _=router.route(.keyDown,event:event(.keyDown,82),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 _=router.route(.keyDown,event:event(.keyDown,0),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 _=router.route(.keyDown,event:event(.keyDown,82),asleep:true,enabled:true,keypadEnabled:true,pid:456)
 let up=router.route(.keyUp,event:event(.keyUp,82),asleep:true,enabled:true,keypadEnabled:true,pid:456)
 check(up.replay.contains { $0.pid==456 && $0.event.type == .keyDown },"M3 fresh Insert belongs to current app after lost release")
 var wake=SleepInsertRouter()
 _=wake.route(.keyDown,event:event(.keyDown,82),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 _=wake.route(.keyDown,event:event(.keyDown,6,flags:.maskShift),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 let freshZ=wake.route(.keyDown,event:event(.keyDown,6),asleep:false,enabled:true,keypadEnabled:true,pid:123)
 check(freshZ.disposition == .pass,"M3 fresh Z is not an old wake repeat")
}
for key in [Int64(59),55,58,56] {
 settings(numbers:true)
 let h=KeyboardHandler(); h.auditPrepare()
 _=h.tapEvent(.keyDown,event(.keyDown,91))
 let flags: CGEventFlags = key==59 ? .maskControl : key==55 ? .maskCommand : key==58 ? .maskAlternate : .maskShift
 _=h.tapEvent(.flagsChanged,event(.flagsChanged,key,flags:flags))
 _=h.tapEvent(.keyDown,event(.keyDown,91,repeatKey:true,flags:flags))
 check(!h.auditLoneState(),"M4 application repeats cancel primary lone modifiers")
}
for key in [Int64(55),58] {
 settings(numbers:true)
 let w=WindowsKeyLayer(); w.auditPrepare()
 _=w.handle(.keyDown,event(.keyDown,91))
 let flags: CGEventFlags = key==55 ? .maskCommand : .maskAlternate
 _=w.handle(.flagsChanged,event(.flagsChanged,key,flags:flags))
 _=w.handle(.keyDown,event(.keyDown,91,repeatKey:true,flags:flags))
 Audit.posts.value=[]
 _=w.handle(.flagsChanged,event(.flagsChanged,key))
 check(Audit.posts.value.isEmpty,"M4 application repeats cancel VoiceOver-layer lone modifiers")
}
settings()
do {
 var router=KeypadEventRouter()
 let s=KeySettings.current
 _=router.route(.keyDown,code:91,flags:[],isRepeat:false,settings:s,modifierHeld:true)
 let repeatResult=router.route(.keyDown,code:91,flags:[],isRepeat:true,settings:s,modifierHeld:true,asleep:true)
 if case .consume=repeatResult { check(true,"M5 owned commands cannot repeat while asleep") } else { check(false,"M5 owned commands cannot repeat while asleep") }
 let up=router.route(.keyUp,code:91,flags:[],isRepeat:false,settings:s,modifierHeld:false,asleep:true)
 if case .consume=up { check(true,"M5 release ownership survives sleep") } else { check(false,"M5 release ownership survives sleep") }
}
do {
 var sleep=SleepInsertRouter()
 _=sleep.route(.keyDown,event:event(.keyDown,82),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 for n in 0..<10000 {
  _=sleep.route(.keyDown,event:event(.keyDown,82,repeatKey:true,flags:n%2==0 ? [] : .maskShift),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 }
 let result=sleep.route(.keyUp,event:event(.keyUp,82),asleep:true,enabled:true,keypadEnabled:true,pid:123)
 check(result.replay.reduce(0) { $0+$1.count } == 10002,"A3 sleeping replay retains every ordinary repeat with changing flags")
 check(result.replay.last?.event.type == .keyUp,"M6 bounding repeats retains the final release")
}
for transition in ["direct","bypass","stop"] {
 for code in [Int64(82),114] {
  settings()
  let h=KeyboardHandler(); h.auditPrepare()
  _=h.tapEvent(.keyDown,event(.keyDown,code))
  if transition=="direct" { InputManager.direct.value=123 }
  if transition=="bypass" { KeyboardHandler.bypass=true }
  if transition=="stop" { h.stop() }
  check(h.tapEvent(.keyDown,event(.keyDown,code,repeatKey:true)) == nil,"A1 owned Insert repeat stays consumed across " + transition)
  check(h.tapEvent(.keyUp,event(.keyUp,code)) == nil,"A1 owned Insert up stays consumed across " + transition)
  check(Audit.deliveries.value.isEmpty,"A1 no unmatched Insert delivery across " + transition)
  let fresh=h.tapEvent(.keyDown,event(.keyDown,code))
  check(transition=="direct" ? Audit.deliveries.value.count==1 : fresh != nil,"A1 fresh Insert follows new routing mode " + transition)
 }
}
for primary in [false,true] {
 for code in [Int64(82),114] {
  settings()
  let h=KeyboardHandler(); h.auditPrepare()
  let w=WindowsKeyLayer(); w.auditPrepare()
  let down=event(.keyDown,code); down.timestamp=10
  _ = primary ? h.tapEvent(.keyDown,down) : w.handle(.keyDown,down)
  Audit.hardwareDown.value=[]
  var history=InsertHardwareHistory(); history.connect(1)
  history.record(connection:1,code:code,down:true,timestamp:10)
  history.record(connection:1,code:code,down:false,timestamp:30)
  Audit.physicalHistory.value=history
  _=InsertModifier.snapshot()
  Audit.commands.value=[]; Audit.posts.value=[]
  let chord=event(.keyDown,91); chord.timestamp=20
  _ = primary ? h.tapEvent(.keyDown,chord) : w.handle(.keyDown,chord)
  check(primary ? Audit.commands.value == ["run:reportCurrentLine"] : Audit.posts.value == [37],"A2 queued chord uses physical state at its timestamp")
  let up=event(.keyUp,code); up.timestamp=30
  _ = primary ? h.tapEvent(.keyUp,up) : w.handle(.keyUp,up)
  Audit.physicalHistory.value=history
  let ordinary=event(.keyDown,0); ordinary.timestamp=40
  check((primary ? h.tapEvent(.keyDown,ordinary) : w.handle(.keyDown,ordinary)) != nil,"A2 typing after release is ordinary")
 }
}
for primary in [false,true] {
 for code in [Int64(82),114] {
  for firstReleased in [UInt64(1),2] {
   for handover in [false,true] {
    for disabling in [false,true] {
     for disconnected in [false,true] {
      settings()
      let h=KeyboardHandler(); h.auditPrepare()
      let w=WindowsKeyLayer(); w.auditPrepare()
      var usePrimary=primary
      func send(_ type:CGEventType,_ e:CGEvent) -> Unmanaged<CGEvent>? { usePrimary ? h.tapEvent(type,e) : w.handle(type,e) }
      let a=event(.keyDown,code); a.timestamp=10; _=send(.keyDown,a)
      let b=event(.keyDown,code); b.timestamp=20; _=send(.keyDown,b)
      var history=InsertHardwareHistory(); history.connect(1); history.connect(2)
      history.record(connection:1,code:code,down:true,timestamp:10)
      history.record(connection:2,code:code,down:true,timestamp:20)
      if handover { if primary { h.auditTearDown() } else { w.stop() }; usePrimary.toggle() }
      if disconnected { history.disconnect(firstReleased) }
      else { history.record(connection:firstReleased,code:code,down:false,timestamp:30) }
      Audit.physicalHistory.value=history
      let firstUp=event(.keyUp,code); firstUp.timestamp=30; Audit.hardwareDown.value.insert(code)
      check(send(.keyUp,firstUp)==nil,"A2 first same-code release remains owned")
      if disabling { config.general.turnOverKey="caps"; KeySettings.refresh() }
      Audit.commands.value=[]; Audit.posts.value=[]
      let chord=event(.keyDown,disabling ? 0 : 91); chord.timestamp=35
      let chordResult=send(.keyDown,chord)
      check(disabling ? chordResult != nil : (usePrimary ? Audit.commands.value == ["run:reportCurrentLine"] : Audit.posts.value == [37]),"A2 other device remains modifier unless setting disabled")
      check(send(.keyDown,event(.keyDown,code,repeatKey:true))==nil,"A2 other device repeat remains owned")
      let remaining:UInt64=firstReleased==1 ? 2 : 1
      history.record(connection:remaining,code:code,down:false,timestamp:50); Audit.physicalHistory.value=history
      let lastUp=event(.keyUp,code); lastUp.timestamp=50
      check(send(.keyUp,lastUp)==nil,"A2 final device release remains paired")
      check(!InsertModifier.snapshot().isHeld,"A2 final device release ends modifier")
     }
    }
   }
  }
  settings()
  let h=KeyboardHandler(); h.auditPrepare()
  let w=WindowsKeyLayer(); w.auditPrepare()
  func sendLate(_ type:CGEventType,_ e:CGEvent) -> Unmanaged<CGEvent>? { primary ? h.tapEvent(type,e) : w.handle(type,e) }
  var late=InsertHardwareHistory(); late.connect(1); late.record(connection:1,code:code,down:false,timestamp:5)
  Audit.physicalHistory.value=late
  let down=event(.keyDown,code); down.timestamp=10; _=sendLate(.keyDown,down)
  Audit.hardwareDown.value=[]
  check(late.observedDown(code:code,at:20,currentDown:false,after:10)==nil,"A2 matching stale up is uncertain after newer Quartz down")
  let uncertain=event(.keyDown,17); uncertain.timestamp=20
  check(sendLate(.keyDown,uncertain) != nil,"A2 incomplete evidence conservatively passes queued chord")
  late.record(connection:1,code:code,down:true,timestamp:10); late.record(connection:1,code:code,down:false,timestamp:30)
  Audit.physicalHistory.value=late
  Audit.commands.value=[]; Audit.posts.value=[]
  let laterQueued=event(.keyDown,91); laterQueued.timestamp=25; _=sendLate(.keyDown,laterQueued)
  check(primary ? Audit.commands.value == ["run:reportCurrentLine"] : Audit.posts.value == [37],"A2 later evidence restores eligible queued modifier")
  let up=event(.keyUp,code); up.timestamp=30; _=sendLate(.keyUp,up)
  let ordinary=event(.keyDown,17); ordinary.timestamp=40
  check(sendLate(.keyDown,ordinary) != nil,"A2 ordinary typing after release stays ordinary")
 }
}
for destination in ["session","direct","windows","teardown"] {
 settings(); Audit.asleep.value=true
 let h=KeyboardHandler(); h.auditPrepare()
 _=h.tapEvent(.keyDown,event(.keyDown,82))
 for _ in 0..<1000 { _=h.tapEvent(.keyDown,event(.keyDown,82,repeatKey:true)) }
 _=h.tapEvent(.keyUp,event(.keyUp,82))
 check(Audit.deliveries.value.count <= KeypadApplicationDelivery.outputBatchLimit,"A3 callback output work is bounded")
 if destination=="direct" { InputManager.direct.value=456 }
 if destination=="windows" {
  let w=WindowsKeyLayer(); w.auditPrepare()
  _=w.handle(.keyDown,event(.keyDown,0))
  _=w.handle(.keyUp,event(.keyUp,0))
 } else {
  _=h.tapEvent(.keyDown,event(.keyDown,0))
  _=h.tapEvent(.keyUp,event(.keyUp,0))
 }
 if destination=="teardown" { h.auditTearDown() }
 while KeypadApplicationDelivery.hasPendingOutput {
  let before=Audit.deliveries.value.count
  KeypadApplicationDelivery.auditDrainBatch()
  check(Audit.deliveries.value.count-before <= KeypadApplicationDelivery.outputBatchLimit,"A3 posting batch is bounded")
 }
 let delivered=Audit.deliveries.value
 check(delivered.count==1004,"A3 all repeats, up and subsequent input survive " + destination)
 check(delivered.prefix(1001).allSatisfy { $0.code==82 && $0.type == .keyDown && $0.pid==123 },"A3 zero repeats retain original destination")
 check(delivered[1001].code==82 && delivered[1001].type == .keyUp,"A3 release follows every repeat")
 check(delivered.suffix(2).map { $0.code } == [0,0],"A3 non-keypad input stays behind replay")
 check(delivered.suffix(2).allSatisfy { $0.pid == (destination=="direct" ? 456 : 0) },"A3 session and explicit destinations remain distinct")
}
for exiting in [false,true] {
 settings(); Audit.asleep.value=true
 let h=KeyboardHandler(); h.auditPrepare()
 _=h.tapEvent(.keyDown,event(.keyDown,82))
 for _ in 0..<1000 { _=h.tapEvent(.keyDown,event(.keyDown,82,repeatKey:true)) }
 _=h.tapEvent(.keyDown,event(.keyDown,0))
 if exiting { KeypadApplicationDelivery.finishForExit() }
 else {
  Audit.retireDuringBatch.value=ObjectIdentifier(h)
  KeypadApplicationDelivery.auditDrainBatch()
  check(Audit.gateDuringBatch.value,"A3 output gate remains active during an in-flight batch")
  while KeypadApplicationDelivery.hasPendingOutput { KeypadApplicationDelivery.auditDrainBatch() }
 }
 let delivered=Audit.deliveries.value
 check(delivered.count==1004,"A3 retirement and exit complete all queued output")
 check(delivered.prefix(1002).allSatisfy { $0.type == .keyDown },"A3 teardown releases never overtake queued downs")
 check(Set(delivered.suffix(2).map { $0.code }) == [0,82] && delivered.suffix(2).allSatisfy { $0.type == .keyUp },"A3 outstanding releases completed once")
 let replacement=WindowsKeyLayer(); replacement.auditPrepare()
 check(replacement.handle(.keyUp,event(.keyUp,82)) == nil,"A3 late physical Insert release remains consumed")
}
// A policy change between two physical downs cannot split an owned same-code episode.
for primary in [false,true] {
 for code in [Int64(82),114] {
  for direct in [false,true] where primary || !direct {
   settings()
   let h=KeyboardHandler(); h.auditPrepare()
   let w=WindowsKeyLayer(); w.auditPrepare()
   func sendMixed(_ type:CGEventType,_ e:CGEvent) -> Unmanaged<CGEvent>? { primary ? h.tapEvent(type,e) : w.handle(type,e) }
   var history=InsertHardwareHistory(); history.connect(1); history.connect(2)
   history.record(connection:1,code:code,down:true,timestamp:10)
   Audit.physicalHistory.value=history
   let a=event(.keyDown,code); a.timestamp=10; _=sendMixed(.keyDown,a)
   if direct { InputManager.direct.value=123 }
   else if code==82 { config.keyboard.keypadCommands=false; KeySettings.refresh() }
   else { config.general.turnOverKey="caps"; KeySettings.refresh() }
   history.record(connection:2,code:code,down:true,timestamp:20); Audit.physicalHistory.value=history
   let b=event(.keyDown,code); b.timestamp=20
   check(sendMixed(.keyDown,b)==nil,"A2 mixed-policy overlap joins already-owned reader episode")
   history.record(connection:1,code:code,down:false,timestamp:30); Audit.physicalHistory.value=history
   let firstUp=event(.keyUp,code); firstUp.timestamp=30; Audit.hardwareDown.value.insert(code)
   check(sendMixed(.keyUp,firstUp)==nil,"A2 mixed-policy first release remains consumed")
   history.record(connection:2,code:code,down:false,timestamp:40); Audit.physicalHistory.value=history
   let finalUp=event(.keyUp,code); finalUp.timestamp=40
   check(sendMixed(.keyUp,finalUp)==nil,"A2 mixed-policy final release remains consumed")
   check(Audit.deliveries.value.isEmpty,"A2 mixed-policy episode never leaks unmatched application events")
  }
  settings()
  let h=KeyboardHandler(); h.auditPrepare()
  let w=WindowsKeyLayer(); w.auditPrepare()
  func sendFresh(_ type:CGEventType,_ e:CGEvent) -> Unmanaged<CGEvent>? { primary ? h.tapEvent(type,e) : w.handle(type,e) }
  let a=event(.keyDown,code); a.timestamp=10; _=sendFresh(.keyDown,a)
  if code==82 { config.keyboard.keypadCommands=false } else { config.general.turnOverKey="caps" }; KeySettings.refresh()
  var history=InsertHardwareHistory(); history.connect(1)
  history.record(connection:1,code:code,down:true,timestamp:10)
  history.record(connection:1,code:code,down:false,timestamp:15)
  history.record(connection:1,code:code,down:true,timestamp:20); Audit.physicalHistory.value=history
  let b=event(.keyDown,code); b.timestamp=20
  check(sendFresh(.keyDown,b) != nil,"A2 genuine fresh down after lost release follows new policy")
  history.record(connection:1,code:code,down:false,timestamp:30); Audit.physicalHistory.value=history
  let up=event(.keyUp,code); up.timestamp=30
  check(sendFresh(.keyUp,up) != nil,"A2 ordinary fresh press retains its matching release")
 }
}
settings()
DispatchQueue.concurrentPerform(iterations: 2_000) { index in
 let code: Int64 = index.isMultiple(of: 2) ? 82 : 114
 let down = CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(code),keyDown:true)!
 _=InsertModifier.handle(.keyDown,event:down,enabled:true,settings:KeySettings.current)
 _=InsertModifier.snapshot()
 let up = CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(code),keyDown:false)!
 _=InsertModifier.handle(.keyUp,event:up,enabled:true,settings:KeySettings.current)
}
Audit.hardwareDown.value=[]
check(!InsertModifier.snapshot().isHeld,"M1 M2 concurrent shared state reconciles released hardware")

// A recorded Caps down must follow current selection, even before the next HID callback.
for primary in [false, true] {
 for choice in ["caps", "both", "insert", "controlOption"] {
  settings()
  config.general.turnOverKey = "caps"; KeySettings.refresh()
  let h = KeyboardHandler(); h.auditPrepare(); h.auditCapsDown(true)
  let w = WindowsKeyLayer(); w.auditPrepare(); w.auditCapsDown(true)
  var proven = InsertAvailability(); proven.connect(1); proven.observePress(connection: 1, code: 114)
  InsertAvailability.current.value = proven
  config.general.turnOverKey = choice; KeySettings.refresh()
  let title = event(.keyDown, 17)
  title.keyboardSetUnicodeString(stringLength: 1, unicodeString: [116])
  let result = primary ? h.tapEvent(.keyDown, title) : w.handle(.keyDown, title)
  let selected = choice == "caps" || choice == "both"
  check((result == nil) == selected, "U3 recorded Caps T follows current selection in both layers")
  let capsEvent = event(.flagsChanged, 57, flags: .maskAlphaShift)
  let capsResult = primary ? h.tapEvent(.flagsChanged, capsEvent) : w.handle(.flagsChanged, capsEvent)
  check((capsResult == nil) == selected, "U3 Caps Lock event passes when not selected")
 }
}

// Preserve the newer App Switcher hooks while retaining ordered replay ownership.
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 let ordered = event(.keyDown, 48, flags: .maskCommand)
 ordered.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.orderedMarker)
 _ = h.tapEvent(.keyDown, ordered)
 check(Audit.callbacks.value == ["clear: Command Tab"], "U4 ordered Command Tab clears leftover modifiers")
 check(Audit.orderedAcknowledgements.value == 1, "U4 ordered Command Tab acknowledges once")
 ordered.type = .keyUp
 _ = h.tapEvent(.keyUp, ordered)
 check(Audit.callbacks.value.count == 1, "U4 ordered Command Tab release does not repeat cleanup")
 check(Audit.orderedAcknowledgements.value == 1, "U4 ordered Command Tab release does not acknowledge")
 _ = h.tapEvent(.flagsChanged, event(.flagsChanged, 55))
 check(Audit.callbacks.value.last == "switcher command released", "U4 physical Command release reaches switcher watcher")
 for watching in [true, false] {
  SwitcherCloseWatcher.isWatching.value = watching
  ScriptHandler.hasDeferredInput.value = !watching
  check(KeyboardHandler.switcherPreparation(settings: KeySettings.current, modifiers: []) != nil, "U4 switcher or deferred work supplies preparation")
  check(KeyboardHandler.switcherPreparation(settings: KeySettings.current, modifiers: .turnover) == nil, "U4 reader chord never becomes deferred Windows remap")
  check(KeyboardHandler.switcherPreparation(settings: KeySettings.current, modifiers: .command) == nil, "U4 Command chord never becomes deferred Windows remap")
 }
}

settings()
do {
 Audit.asleep.value = true
 let h = KeyboardHandler(); h.auditPrepare()
 _ = h.tapEvent(.keyDown, event(.keyDown, 82))
 // Exceed the 32-event synchronous batch so this is genuinely queued output.
 for _ in 0..<100 { _ = h.tapEvent(.keyDown, event(.keyDown, 82, repeatKey: true)) }
 _ = h.tapEvent(.keyUp, event(.keyUp, 82))
 check(KeypadApplicationDelivery.hasPendingOutput, "U4 ordered Command Tab has a keypad backlog")
 for type in [CGEventType.keyDown, .keyUp] {
  let tab = event(type, 48, flags: .maskCommand)
  tab.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.orderedMarker)
  check(h.tapEvent(type, tab) == nil, "U4 ordered Command Tab pair queues behind keypad replay")
 }
 check(Audit.orderedTrace.value == ["clear", "ack"], "U4 Command Tab clears modifiers before acknowledgement exactly once")
 check(Audit.deliveries.value.isEmpty, "U4 acknowledgement does not overtake replay with immediate delivery")
 while KeypadApplicationDelivery.hasPendingOutput { KeypadApplicationDelivery.auditDrainBatch() }
 check(Audit.deliveries.value.map { $0.code } == Array(repeating: Int64(82), count: 102) + [48, 48], "U4 Command Tab output follows keypad down and up")
 check(Audit.deliveries.value.map { $0.type } == Array(repeating: CGEventType.keyDown, count: 101) + [.keyUp, .keyDown, .keyUp], "U4 Command Tab preserves both complete key pairs")
}
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 SwitcherCloseWatcher.isWatching.value = true
 _ = h.tapEvent(.keyDown, event(.keyDown, 118, flags: .maskControl))
 check(Audit.callbacks.value.contains("switcher preparation supplied"), "U4 tap passes deferred preparation to upstream dispatcher")
 let gesture = KeyboardGesture(keyCode: 118, modifiers: .control, characters: "", timestamp: 0, isRepeat: false, flags: .maskControl)
 let prepare = KeyboardHandler.switcherPreparation(settings: KeySettings.current, modifiers: .control)
 let prepared = prepare?(gesture)
 check(prepared?.keyCode == 13, "U4 deferred Control F4 remaps to W")
 check(prepared?.modifiers == .command, "U4 deferred Control F4 keeps Command modifier")
}

// The integrated upstream ordered lane must join queued replay before acknowledging.
for redirect in [false, true] {
 settings(); Audit.asleep.value = true
 let h = KeyboardHandler(); h.auditPrepare()
 _ = h.tapEvent(.keyDown, event(.keyDown, 82))
 for _ in 0..<100 { _ = h.tapEvent(.keyDown, event(.keyDown, 82, repeatKey: true)) }
 _ = h.tapEvent(.keyUp, event(.keyUp, 82))
 check(KeypadApplicationDelivery.hasPendingOutput, "U1 replay backlog exists")
 if redirect { KeyboardHandler.redirectPid = 456 }
 for type in [CGEventType.keyDown, .keyUp] {
  let ordered = event(type, 0)
  ordered.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.orderedMarker)
  check(h.tapEvent(type, ordered) == nil, "U1 ordered output is deferred behind replay")
 }
 check(Audit.orderedAcknowledgements.value == 1, "U1 ordered down acknowledged once, up never acknowledged")
 while KeypadApplicationDelivery.hasPendingOutput { KeypadApplicationDelivery.auditDrainBatch() }
 let output = Audit.deliveries.value
 check(output.count == 104, "U1 every replay and ordered event delivered once")
 check(output.prefix(101).allSatisfy { $0.code == 82 && $0.type == .keyDown && $0.pid == 123 }, "U1 replay downs stay first")
 check(output.dropFirst(101).first?.type == .keyUp, "U1 replay release precedes ordered output")
 check(output.suffix(2).map { $0.type } == [.keyDown, .keyUp], "U1 ordered pair stays paired")
 check(output.suffix(2).allSatisfy { $0.code == 0 && $0.pid == (redirect ? 456 : 0) }, "U1 ordered destination preserved")
 check(Audit.orderedAcknowledgements.value == 1, "U1 replay drain does not acknowledge again")
}
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 _ = h.tapEvent(.keyDown, event(.keyDown, 82))
 let ordered = event(.keyDown, 82, repeatKey: true)
 ordered.setIntegerValueField(.eventSourceUserData, value: KeyboardHandler.orderedMarker)
 check(h.tapEvent(.keyDown, ordered) != nil, "U1 ordered zero bypasses physical Insert ownership without backlog")
 check(Audit.orderedAcknowledgements.value == 1, "U1 immediate ordered output acknowledged")
}
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 KeyboardHandler.bypass = true
 let toggle = event(.keyDown, 96, flags: .maskCommand)
 _ = h.tapEvent(.keyDown, toggle)
 check(Audit.callbacks.value == ["person toggle"], "U2 physical toggle observed before bypass")
 for source in [KeyboardHandler.marker, KeyboardHandler.orderedMarker] {
  toggle.setIntegerValueField(.eventSourceUserData, value: source)
  _ = h.tapEvent(.keyDown, toggle)
 }
 _ = h.tapEvent(.keyDown, event(.keyDown, 96, repeatKey: true, flags: .maskCommand))
 _ = h.tapEvent(.keyUp, event(.keyUp, 96, flags: .maskCommand))
 _ = h.tapEvent(.keyDown, event(.keyDown, 96))
 check(Audit.callbacks.value == ["person toggle"], "U2 synthetic, repeat, up and wrong shortcut do not count as person toggles")
 KeyboardHandler.bypass = false
 _ = h.tapEvent(.tapDisabledByTimeout, event(.tapDisabledByTimeout, 0))
 h.auditTearDown()
 check(Audit.callbacks.value.suffix(2) == ["listening", "stopped"], "U2 recovery and teardown preserve toggle listening notifications")
}
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 _ = h.tapEvent(.keyDown, event(.keyDown, 91))
 check(Audit.callbacks.value == ["browse bypass", "keypad command"], "U2 keypad invalidates browse evidence before command")
}
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 ArrowQuickNav.applies.value = true
 let arrow = event(.keyDown, 126)
 arrow.timestamp = 24_000_000
 check(h.tapEvent(.keyDown, arrow) == nil, "U2 Quick Nav consumes arrow down")
 var timebase = mach_timebase_info_data_t()
 mach_timebase_info(&timebase)
 let expectedTime = UInt64(Double(arrow.timestamp) / (Double(timebase.numer) / Double(timebase.denom)))
 check(Audit.findTimes.value == [expectedTime], "U2 Find close retains arrow timestamp on gesture clock")
 check(Audit.callbacks.value == ["find close: a Quick Nav arrow", "browse bypass"], "U2 Quick Nav closes Find before browse invalidation")
 _ = h.tapEvent(.keyUp, event(.keyUp, 126))
 check(Audit.callbacks.value.last == "arrow: upArrow", "U2 Quick Nav release performs single move")
}

// Exercise the real serial posting worker alongside producers and reader retirement.
// Keep this last: graceful exit closes delivery, and no later test resets shared state.
settings()
Audit.asynchronousOutput.value = true
let sleepingReader = KeyboardHandler()
let sleepingOwner = ObjectIdentifier(sleepingReader)
let typingReader = KeyboardHandler()
let typingOwner = ObjectIdentifier(typingReader)
let retiringReader = KeyboardHandler()
let retiringOwner = ObjectIdentifier(retiringReader)
_ = KeypadApplicationDelivery.routeSleeping(owner:sleepingOwner,type:.keyDown,event:event(.keyDown,82),asleep:true,enabled:true,keypadEnabled:true,pid:123)
for _ in 0..<10_000 {
 _ = KeypadApplicationDelivery.routeSleeping(owner:sleepingOwner,type:.keyDown,event:event(.keyDown,82,repeatKey:true),asleep:true,enabled:true,keypadEnabled:true,pid:123)
}
KeypadApplicationDelivery.retireSleeping(owner:sleepingOwner)
_ = KeypadApplicationDelivery.deliverDown(owner:typingOwner,code:91,flags:[],event:event(.keyDown,91),pid:456)
_ = KeypadApplicationDelivery.deliverDown(owner:retiringOwner,code:92,flags:[],event:event(.keyDown,92),pid:789)
DispatchQueue.concurrentPerform(iterations:3) { worker in
 if worker == 0 {
  for _ in 0..<2_000 {
   _ = KeypadApplicationDelivery.continueEvent(owner:typingOwner,.keyDown,event(.keyDown,91,repeatKey:true))
  }
 } else if worker == 1 {
  KeypadApplicationDelivery.finishSleeping(owner:sleepingOwner)
 } else {
  KeypadApplicationDelivery.finish(owner:retiringOwner)
 }
}
KeypadApplicationDelivery.finishForExit()
let asyncDeliveries = Audit.deliveries.value
check(Audit.workerBatches.value > 0,"A3 real asynchronous posting worker executed")
check(!KeypadApplicationDelivery.hasPendingOutput,"A3 graceful exit drained concurrent output")
for (code,pid,count) in [(Int64(82),Int32(123),10_002),(91,456,2_002),(92,789,2)] {
 let stream = asyncDeliveries.filter { $0.code == code }
 check(stream.count == count,"A3 async worker conserves every event for code \(code)")
 check(stream.allSatisfy { $0.pid == pid },"A3 async worker preserves original destination for code \(code)")
 check(stream.first?.type == .keyDown && stream.last?.type == .keyUp,"A3 async stream starts with down and ends with release for code \(code)")
 check(stream.filter { $0.type == .keyUp }.count == 1,"A3 async retirement releases exactly once for code \(code)")
 check(stream.dropLast().allSatisfy { $0.type == .keyDown },"A3 async repeats cannot overtake release for code \(code)")
}

// Maintainer PR366: the optional layer must not acquire a keypad without opt-in.
for style in ["windows", "jaws"] {
 for desktop in [false, true] {
  for insert in [false, true] {
   settings()
   config.general.keyboardStyle = style
   config.general.turnOverKey = insert ? "insert" : "both"
   config.keyboard.layout = desktop ? "desktop" : "laptop"
   KeySettings.refresh()
   let w = WindowsKeyLayer(); w.auditPrepare()
   let optedIn = insert || (style == "jaws" && desktop)
   let down = w.handle(.keyDown, event(.keyDown,71))
   check((down == nil) == optedIn, "U5 optional Clear requires explicit keypad opt-in")
   config.general.turnOverKey = "both"; config.keyboard.layout = "laptop"; KeySettings.refresh()
   let up = w.handle(.keyUp, event(.keyUp,71))
   check((up == nil) == optedIn, "U5 Clear release retains original ownership after opt-out")
  }
 }
}

// Actual production Caps callbacks and chord routing, with only OS lock writes replaced.
for primary in [false, true] {
 settings()
 let h = KeyboardHandler(); h.auditPrepare()
 let w = WindowsKeyLayer(); w.auditPrepare()
 func caps(_ pressed: Bool, _ time: UInt64) {
  if primary { h.capsChanged(pressed: pressed, timestamp: time) }
  else { w.capsChanged(pressed: pressed, timestamp: time) }
 }
 func title() -> Bool {
  // Distinct human presses, not three synthetic copies inside the 8 ms echo guard.
  Audit.keyTime.value = (Audit.keyTime.value ?? 0) + 30_000_000
  let e = event(.keyDown,17); e.timestamp = 100
  e.keyboardSetUnicodeString(stringLength:1, unicodeString:[116])
  let consumed = (primary ? h.tapEvent(.keyDown,e) : w.handle(.keyDown,e)) == nil
  e.type = .keyUp
  _ = primary ? h.tapEvent(.keyUp,e) : w.handle(.keyUp,e)
  return consumed
 }
 caps(true,10)
 check(title(), "U6 unproven Insert has a working Caps title chord in both layers")
 var hardware = InsertAvailability(); hardware.connect(1); hardware.observePress(connection:1,code:82)
 InsertAvailability.current.value = hardware
 check(!KeySettings.current.capsIsTurnOver, "U6 proven keypad changes next-press policy")
 check(title(), "U6 held fallback still works when Insert becomes proven")
 caps(false,20)
 caps(true,30)
 check(!title(), "U6 next Caps press is ordinary while Insert available")
 hardware.disconnect(1); InsertAvailability.current.value = hardware
 check(!title(), "U6 unplug does not capture an already-held ordinary Caps")
 caps(false,40)
 caps(true,50)
 check(title(), "U6 next fresh Caps works after disconnect")
 caps(false,60)
 if primary { check(!KeyboardHandler.capsHeld.value.down, "U6 shared held state is cleared on release") }
}
for primary in [false,true] {
 settings()
 let h = KeyboardHandler(); h.auditPrepare()
 let w = WindowsKeyLayer(); w.auditPrepare()
 func caps(_ pressed: Bool, _ time: UInt64) {
  if primary { h.capsChanged(pressed:pressed,timestamp:time) }
  else { w.capsChanged(pressed:pressed,timestamp:time) }
 }
 var hardware = InsertAvailability(); hardware.connect(1); hardware.observePress(connection:1,code:114)
 InsertAvailability.current.value = hardware
 caps(true,10)
 let ordinary = event(.flagsChanged,57,flags:.maskAlphaShift); ordinary.timestamp = 10
 check((primary ? h.tapEvent(.flagsChanged,ordinary) : w.handle(.flagsChanged,ordinary)) != nil, "U7 ordinary Caps flags pass")
 caps(false,20)
 hardware.disconnect(1); InsertAvailability.current.value = hardware
 caps(true,30)
 check(Audit.lockStates.value.last == true, "U7 fallback preserves previously enabled ordinary Caps Lock")
 caps(false,40)
}

// Quartz may arrive before the new HID down after the previous episode ended.
for primary in [false,true] {
 settings()
 let h = KeyboardHandler(); h.auditPrepare()
 let w = WindowsKeyLayer(); w.auditPrepare()
 func caps(_ pressed: Bool, _ time: UInt64) {
  if primary { h.capsChanged(pressed:pressed,timestamp:time) }
  else { w.capsChanged(pressed:pressed,timestamp:time) }
 }
 func flags(_ time: UInt64) -> Bool {
  let e=event(.flagsChanged,57,flags:.maskAlphaShift); e.timestamp=time
  return (primary ? h.tapEvent(.flagsChanged,e) : w.handle(.flagsChanged,e)) == nil
 }
 caps(true,10); caps(false,20)
 var hw=InsertAvailability(); hw.connect(1); hw.observePress(connection:1,code:114)
 InsertAvailability.current.value=hw
 check(!flags(30), "U8 ended fallback must not swallow next ordinary Caps before HID")
 caps(true,30); caps(false,40)
 hw.disconnect(1); InsertAvailability.current.value=hw
 check(flags(50), "U8 ended ordinary press must not pass next fallback before HID")
 caps(true,50); caps(false,60)
 check(flags(20), "U8 queued old fallback release retains its original episode")
 check(!flags(40), "U8 queued old ordinary release remains ordinary")
}

// Exercise the actual locked publication boundary under the sanitizer too.
settings()
do {
 let finished = DispatchGroup()
 let invalid = Locked(false)
 var hardware = InsertAvailability(); hardware.connect(1); hardware.observePress(connection:1,code:82)
 let known = hardware
 for worker in 0..<4 {
  finished.enter()
  DispatchQueue.global().async {
   defer { finished.leave() }
   for i in 0..<2_000 {
    if worker == 0 { InsertAvailability.current.value = i.isMultiple(of:2) ? known : InsertAvailability() }
    else {
     let s = KeySettings.current
     if !s.insertIsTurnOver || s.controlOptionIsTurnOver { invalid.value = true }
    }
   }
  }
 }
 finished.wait()
 check(!invalid.value, "U9 concurrent availability publication preserves configured modifier snapshots")
 check(KeySettings.current.capsIsTurnOver, "U9 final disconnected publication restores fallback")
}

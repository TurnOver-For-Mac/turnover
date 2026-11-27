
// Follow-up review: Clear reports a modifier change only when one occurred.
settings()
do {
 var messages: [String] = []
 TurnOverCore.Keypad.toggleWindows { messages.append($0) }
 check(messages == ["keypad numbers"], "F1 unproven hardware leaves fallback unchanged without redundant speech: \(messages)")
 TurnOverCore.Keypad.toggleWindows { messages.append($0) }
 check(messages.last == "keypad commands", "F1 commands mode still has unchanged fallback")
 var hardware = InsertAvailability(); hardware.connect(1); hardware.observePress(connection:1,code:114)
 InsertAvailability.current.value = hardware
 TurnOverCore.Keypad.toggleWindows { messages.append($0) }
 check(messages.last == "keypad numbers", "F1 separate Insert remains available without redundant speech")
}

// A direct application receives native Caps flags, but the reader still observes state.
settings()
do {
 let h = KeyboardHandler(); h.auditPrepare()
 var hardware = InsertAvailability(); hardware.connect(1); hardware.observePress(connection:1,code:114)
 InsertAvailability.current.value = hardware
 InputManager.direct.value = 123
 let flags = event(.flagsChanged,57,flags:.maskAlphaShift); flags.timestamp = 10
 _ = h.tapEvent(.flagsChanged,flags)
 InputManager.direct.value = nil
 hardware.disconnect(1); InsertAvailability.current.value = hardware
 h.capsChanged(pressed:true,timestamp:30)
 check(Audit.lockStates.value.last == true, "F2 direct-app native Caps on is retained by fallback")
 h.capsChanged(pressed:false,timestamp:40)
}

// The real lock sample precedes fallback publication, never an owned Caps toggle.
for primary in [false,true] {
 for on in [false,true] {
  settings()
  let h = KeyboardHandler(); h.auditPrepare()
  let w = WindowsKeyLayer(); w.auditPrepare()
  CapsLockRecovery.current.value = .init(timestamp:20,on:on)
  if primary { h.capsChanged(pressed:true,timestamp:30) }
  else { w.capsChanged(pressed:true,timestamp:30) }
  check(Audit.lockStates.value.last == on, "F3 fallback adopts actual lock sample on both layers")
  // A held press must retain its lock state even if hardware availability changes again.
  CapsLockRecovery.current.value = .init(timestamp:35,on:!on)
  if primary { h.capsChanged(pressed:false,timestamp:40) }
  else { w.capsChanged(pressed:false,timestamp:40) }
  check(Audit.lockStates.value.last == on, "F3 release cannot adopt a later sample mid-episode")
 }
}
settings()
do {
 var hw = InsertAvailability(); hw.connect(1); hw.observePress(connection:1,code:82)
 InsertAvailability.current.value = hw
 var words: [String] = []
 TurnOverCore.Keypad.toggleWindows { words.append($0) }
 check(words.last == "keypad numbers. Caps Lock is now the TurnOver key", "F4 actual Clear fallback change has one complete message: \(words)")
 TurnOverCore.Keypad.toggleWindows { words.append($0) }
 check(words.last == "keypad commands. Insert is available. Caps Lock is now a lock key", "F4 actual Clear recovery has one complete message")
}

settings()
do {
 CapsLockRecovery.publish(.init(timestamp:20,on:true))
 CapsLockRecovery.publish(.init(timestamp:10,on:false))
 check(CapsLockRecovery.current.value?.on == true, "F5 older concurrent capture cannot overwrite newer sample")
 let h = KeyboardHandler(); h.auditPrepare()
 h.realCapsOn = false; h.capsStateTimestamp = 25
 h.capsChanged(pressed:true,timestamp:30)
 check(Audit.lockStates.value.last == false, "F5 startup read newer than global snapshot wins")
}
for primary in [false,true] {
 settings()
 let h = KeyboardHandler(); h.auditPrepare()
 let w = WindowsKeyLayer(); w.auditPrepare()
 var hw = InsertAvailability(); hw.connect(1); hw.observePress(connection:1,code:114)
 InsertAvailability.current.value = hw
 CapsLockRecovery.current.value = .init(timestamp:10,on:false)
 let flags = event(.flagsChanged,57,flags:.maskAlphaShift); flags.timestamp = 20
 _ = primary ? h.tapEvent(.flagsChanged,flags) : w.handle(.flagsChanged,flags)
 hw.disconnect(1); InsertAvailability.current.value = hw
 if primary { h.capsChanged(pressed:true,timestamp:30) }
 else { w.capsChanged(pressed:true,timestamp:30) }
 check(Audit.lockStates.value.last == true, "F5 newer native flags supersede earlier recovery sample")
}

settings()
do {
 let done = DispatchGroup()
 for worker in 0..<4 {
  done.enter()
  DispatchQueue.global().async {
   defer { done.leave() }
   for i in 1...500 {
    CapsLockRecovery.publish(.init(timestamp:UInt64(i*4+worker),on:worker == 3))
   }
  }
 }
 done.wait()
 check(CapsLockRecovery.current.value?.timestamp == 2003, "F6 concurrent samples retain newest timestamp")
 check(CapsLockRecovery.current.value?.on == true, "F6 newest sample retains matching lock value")
}

// Feed both live timestamp representations through the actual Caps and Insert callbacks.
for primary in [false,true] {
 for useTicks in [false,true] {
  settings()
  let h = KeyboardHandler(); h.auditPrepare()
  let w = WindowsKeyLayer(); w.auditPrepare()
  let tick = mach_absolute_time()
  let ns = KeyboardEventTime.nanoseconds(tick)
  Audit.eventUptime.value = ns + 1_000_000
  var hw = InsertAvailability(); hw.connect(1); hw.observePress(connection:1,code:114)
  InsertAvailability.current.value = hw
  CapsLockRecovery.current.value = .init(timestamp:ns-1,on:false)
  let flags = event(.flagsChanged,57,flags:.maskAlphaShift)
  flags.timestamp = useTicks ? tick : ns
  let passed = primary ? h.tapEvent(.flagsChanged,flags) : w.handle(.flagsChanged,flags)
  check(passed != nil, "F7 ordinary Caps flags pass with either Quartz timestamp domain")
  hw.disconnect(1); InsertAvailability.current.value = hw
  if primary { h.capsChanged(pressed:true,timestamp:ns+1) }
  else { w.capsChanged(pressed:true,timestamp:ns+1) }
  check(Audit.lockStates.value.last == true, "F7 recent Caps flags outrank a stale recovery sample")
 }
}
for useTicks in [false,true] {
 settings()
 let h = KeyboardHandler(); h.auditPrepare()
 let w = WindowsKeyLayer(); w.auditPrepare()
 let tick = mach_absolute_time()
 let ns = KeyboardEventTime.nanoseconds(tick)
 Audit.eventUptime.value = ns + 1_000_000
 var history = InsertHardwareHistory(); history.connect(1)
 let down = event(.keyDown,114)
 down.timestamp = useTicks ? tick-30 : KeyboardEventTime.nanoseconds(tick-30)
 _ = h.tapEvent(.keyDown,down)
 history.record(connection:1,code:114,down:true,timestamp:KeyboardEventTime.nanoseconds(tick-30))
 history.record(connection:1,code:114,down:false,timestamp:KeyboardEventTime.nanoseconds(tick+30))
 Audit.physicalHistory.value = history; Audit.hardwareDown.value = []
 let chord = event(.keyDown,91)
 chord.timestamp = useTicks ? tick : ns
 _ = w.handle(.keyDown,chord)
 check(Audit.posts.value == [37], "F8 held Insert survives handover for either Quartz timestamp domain")
}

// Observe real handler output against the host Mach clock for both event stamp representations.
for useTicks in [false, true] {
 settings()
 let h = KeyboardHandler(); h.auditPrepare()
 let key = event(.keyDown, 0)
 let before = mach_absolute_time()
 let stamp = mach_absolute_time()
 key.timestamp = useTicks ? stamp : KeyboardEventTime.nanoseconds(stamp)
 Audit.eventUptime.value = DispatchTime.now().uptimeNanoseconds
 _ = h.tapEvent(.keyDown, key)
 let after = mach_absolute_time()
 let times = Audit.gestureTimes.value
 check(times.count == 1, "F9 the real keyboard callback dispatches one gesture")
 check(times.allSatisfy { $0 >= before - 1 && $0 <= after }, "F9 its timestamp is on the host Mach clock")
}

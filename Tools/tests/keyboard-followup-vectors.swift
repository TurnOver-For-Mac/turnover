
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

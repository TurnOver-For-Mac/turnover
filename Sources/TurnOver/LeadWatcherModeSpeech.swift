// SPDX-License-Identifier: GPL-3.0-or-later
// This production extension is also compiled by the isolated mode-wiring harness.
import Foundation
import TurnOverCore

extension LeadWatcher {
    func sayModeWhenReady(_ text: String, generation: Int) {
        modeDelivery.announce(text, now: { ProcessInfo.processInfo.systemUptime },
                              schedule: { delay, action in
                                  self.scheduleModeSpeech(after: delay, action: action)
                              }, current: { [weak self] in
                                  guard let self else { return false }
                                  return self.choiceGeneration == generation && self.spokenModeGeneration != generation
                              },
                              readyReader: { [weak self] in self?.readyModeReader(generation: generation) },
                              output: { [weak self] text, reader in
                                  guard let self else { return }
                                  self.spokenModeGeneration = generation
                                  Self.nextTakeoverWords = nil
                                  // Keep the selected-reader route, and validate the generation and
                                  // current reader again before the AppleScript submission as well.
                                  if reader == .turnOver { Speech.speakMessage(text) }
                                  else {
                                      VoiceOverSpeak.sayToVoiceOver(text, current: { [weak self] in
                                          guard let self else { return false }
                                          return self.choiceGeneration == generation &&
                                              self.readyModeReader(generation: generation) == .voiceOver
                                      })
                                  }
                              })
    }
}

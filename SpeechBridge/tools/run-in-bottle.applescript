-- Runs the command in run-in-bottle.cmd (beside this app's Resources) inside the CrossOver
-- bottle "Steam", from the GUI login session. Started from a shell, a bottle client never
-- meets the wineserver (MSync's Mach bootstrap port is not visible there) and hangs.
-- Output lands in run-in-bottle.out next to the .cmd file; "done" is appended at the end.
set dir to (POSIX path of (path to home folder)) & "Library/Application Support/SpeechBridge/run-in-bottle"
set cmdline to do shell script "cat " & quoted form of (dir & "/cmd")
do shell script "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart --bottle Steam --no-update " & cmdline & " > " & quoted form of (dir & "/out") & " 2>&1; echo done >> " & quoted form of (dir & "/out")

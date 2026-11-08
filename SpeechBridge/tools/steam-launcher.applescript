-- Starts the Windows Steam client that lives in the CrossOver bottle "Steam".
-- It uses CrossOver's command-line starter (cxstart) from this app's own session, so the
-- CrossOver window never opens. Started from a shell that has no window-server session it
-- would die three minutes in (measured 28 Sep 2026); an applet is fine — the run-in-bottle
-- helper has launched bottle programs this way all along.
-- If Steam is already running, this does nothing except bring it forward.
set steamExe to (POSIX path of (path to home folder)) & "Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe"
set cxstart to "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart"
set steamIsUp to do shell script "pgrep -f 'Steam\\\\steam.exe' >/dev/null && echo yes || echo no"
if steamIsUp is "yes" then
	try
		tell application "System Events" to set frontmost of first process whose name is "steam.exe" to true
	end try
	return
end if
-- Steam is started by the bottle's script host rather than directly: a program launched by
-- another Windows program gets CrossOver's per-process package, so the app switcher calls
-- it "steam.exe" instead of "wine". (A cmd "start" would do the same but leaves a console
-- host behind; wscript has no window.) tools/steam.vbs lives at C:\SpeechBridge\steam.vbs.
do shell script quoted form of cxstart & " --bottle Steam --no-update --no-wait --no-gui 'C:\\windows\\system32\\wscript.exe' 'C:\\SpeechBridge\\steam.vbs' > /dev/null 2>&1 < /dev/null &"
-- Then give every game its own name in the app switcher (see tools/name-stubs.sh); it waits
-- for the bottle to be up and runs in the background so this app can quit.
set stubs to (POSIX path of (path to application support folder from user domain)) & "SpeechBridge/name-stubs.sh"
do shell script "sh " & quoted form of stubs & " Steam > /dev/null 2>&1 < /dev/null &"

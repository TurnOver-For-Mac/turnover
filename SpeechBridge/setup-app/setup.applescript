-- SpeechBridge Setup: makes every Windows game speak through TurnOver.
-- Runs the copies of install-notproton.sh (games Steam on the Mac runs through NotProton) and,
-- if a CrossOver bottle called Steam still exists, install.sh (games in that bottle). Safe to
-- run any time: after installing a game, after its first launch, after a Steam "verify integrity".
set payload to (POSIX path of (path to me)) & "Contents/Resources/SpeechBridge/"
set report to ""
try
	set report to do shell script "sh " & quoted form of (payload & "install-notproton.sh") & " 2>&1"
on error msg
	set report to "The NotProton installer stopped with an error:" & return & msg
end try
set bottle to (POSIX path of (path to home folder)) & "Library/Application Support/CrossOver/Bottles/Steam/drive_c"
tell application "System Events" to set hasBottle to exists folder bottle
if hasBottle then
	try
		set report to report & return & "CrossOver bottle:" & return & (do shell script "sh " & quoted form of (payload & "install.sh") & " 2>&1")
	on error msg
		set report to report & return & "The bottle installer stopped with an error:" & return & msg
	end try
end if
set summary to ""
repeat with l in paragraphs of report
	set t to l as string
	if t is not "" and t does not start with "SpeechBridge " then set summary to summary & t & return
end repeat
if summary is "" then set summary to "Nothing needed doing."
display dialog "SpeechBridge is set up." & return & return & summary buttons {"OK"} default button "OK" with title "SpeechBridge Setup" giving up after 300

on open fileList
	if (count of fileList) is 0 then return
	set theFile to POSIX path of (item 1 of fileList)
	set binary to quoted form of (POSIX path of (path to me) & "Contents/Resources/nordpiano")
	tell application "Terminal"
		activate
		do script binary & " play " & quoted form of theFile
	end tell
end open

on run
	set f to choose file with prompt "Choose a Nord Piano (.npno) file" of type {"npno"}
	open {f}
end run

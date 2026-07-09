-- claude-prewarm notifier
--
-- Compiled by install.sh into "Claude Prewarm.app" so notifications carry the
-- claude-prewarm icon instead of the generic Script Editor icon. The CLI invokes
-- the built applet with the title/message passed as the CP_TITLE / CP_MESSAGE
-- environment variables (exec'ing an applet binary directly does not forward argv
-- to `on run argv`, so env vars are the reliable channel). A positional argv path
-- is kept as a fallback for manual testing.

on run argv
	set t to ""
	set m to ""
	try
		-- do shell script decodes UTF-8; system attribute would return raw bytes
		set t to do shell script "printf '%s' \"$CP_TITLE\""
	end try
	try
		set m to do shell script "printf '%s' \"$CP_MESSAGE\""
	end try
	if t is "" and m is "" then
		try
			set t to item 1 of argv
			set m to item 2 of argv
		end try
	end if
	if t is "" then set t to "Claude prewarm"
	display notification m with title t
	delay 1
end run

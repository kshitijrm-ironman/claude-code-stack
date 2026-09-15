' headroom-silent.vbs - template
'
' Launches the Headroom proxy with no console window, pointed upstream at pxpipe.
' Rendered by scripts/03-install-headroom.ps1 to %USERPROFILE%\headroom-silent.vbs
' with {{...}} placeholders substituted.
'
' Placeholders:
'   {{HEADROOM_EXE}}    - full path to headroom.exe
'   {{HEADROOM_PORT}}   - port Headroom listens on (default 8787)
'   {{UPSTREAM_URL}}    - pxpipe base URL (default http://127.0.0.1:47821)
'
' WshShell.Run args: 0 = hidden window, False = do not wait for exit.

Set WshShell = CreateObject("WScript.Shell")
WshShell.Run """{{HEADROOM_EXE}}"" proxy --port {{HEADROOM_PORT}} --anthropic-api-url {{UPSTREAM_URL}}", 0, False

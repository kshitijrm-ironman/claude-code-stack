' pxpipe-silent.vbs - template
'
' Launches the pxpipe proxy with no console window.
' Rendered by scripts/02-install-pxpipe.ps1 to %USERPROFILE%\pxpipe-silent.vbs
' with {{...}} placeholders substituted.
'
' Placeholders:
'   {{NODE_EXE}}    - full path to node.exe
'   {{PXPIPE_CLI}}  - full path to pxpipe-proxy\bin\cli.js
'
' WshShell.Run args: 0 = hidden window, False = do not wait for exit.

Set WshShell = CreateObject("WScript.Shell")
WshShell.Run """{{NODE_EXE}}"" ""{{PXPIPE_CLI}}""", 0, False

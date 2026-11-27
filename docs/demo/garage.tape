# README recording: `garage status` and a full `sudo garage test` run on the
# real host, sped up. Output goes through docs/demo/redact, which replaces the
# host's addresses, domain, ids and the bay names with labels. Set DEMO_BAY to
# the bay to test (a bay without VPN egress); it is typed and shown as "alice".
#
#   DEMO_BAY=<bay> nix run nixpkgs#vhs -- docs/demo/garage.tape
#   python3 docs/demo/trim.py docs/demo/garage.gif docs/demo/garage.gif 2500   # needs Pillow
Output docs/demo/garage.gif

Set Shell bash
Set FontSize 14
Set Width 1200
Set Height 760
Set Padding 24
Set Theme "GitHub Dark"
Set TypingSpeed 45ms
Set WaitTimeout 600s
Set WaitPattern /^\$\s*$/
Set PlaybackSpeed 5

Hide
Type `export PS1='$ ' DEMO_BAY_LABEL=alice DEMO_COLS=$(tput cols); export DEMO_BAY; garage() { command garage "$@" 2>&1 | docs/demo/redact; }; sudo() { command sudo "${@/#alice/$DEMO_BAY}" 2>&1 | docs/demo/redact; }; clear`
Enter
Sleep 500ms
Show

Type "garage status"
Sleep 300ms
Enter
Sleep 12s
Type "sudo garage test alice"
Sleep 300ms
Enter
Wait
Sleep 8s

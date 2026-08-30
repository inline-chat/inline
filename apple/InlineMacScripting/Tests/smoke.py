#!/usr/bin/env python3
"""Run after `swift test --package-path apple/InlineMacScripting`.

Builds a fixture bundle in the package's normal .build directory. It never opens
Inline or uses an account/network. Requires permission to automate the fixture.
"""
from pathlib import Path
import plistlib
import os
import signal
import shutil
import subprocess
import time

package = Path(__file__).resolve().parents[1]
binary_dir = Path(subprocess.check_output(
    ["swift", "build", "--package-path", str(package), "--show-bin-path"], text=True
).strip())
bundle = package / ".build" / "InlineScriptingFixture.app"
contents = bundle / "Contents"
executable = contents / "MacOS" / "InlineScriptingFixture"

def fixture_pids():
    result = subprocess.run(["pgrep", "-fx", str(executable)], text=True, capture_output=True)
    return [int(pid) for pid in result.stdout.split()]

if fixture_pids():
    raise SystemExit("Close the existing InlineScriptingFixture before running this test.")
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
shutil.copy2(binary_dir / "InlineScriptingFixture", contents / "MacOS" / "InlineScriptingFixture")
shutil.copy2(package / "Resources" / "Inline.sdef", contents / "Resources" / "Inline.sdef")
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump({
        "CFBundleIdentifier": "chat.inline.ScriptingFixture",
        "CFBundleExecutable": "InlineScriptingFixture",
        "CFBundleName": "InlineScriptingFixture",
        "CFBundlePackageType": "APPL",
        "NSAppleScriptEnabled": True,
        "OSAScriptingDefinition": "Inline.sdef",
        "LSUIElement": True,
    }, file)
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)

script = '''
on requireTrue(condition, labelText)
  if not condition then error "Failed: " & labelText
end requireTrue
tell application "BUNDLE_PATH"
  my requireTrue(show inline, "show")
  set accountInfo to current account
  my requireTrue((user id of accountInfo) is "9223372036854775807", "64-bit account ID")
  my requireTrue((display name of accountInfo) is "Fixture 🦊", "Unicode record")
  my requireTrue((current chat) is missing value, "missing selection")
  set spacesFound to list spaces maximum count 1 start offset 0
  my requireTrue((space id of item 1 of spacesFound) is "7", "spaces")
  set usersFound to list users in space "7" maximum count 1 start offset 0
  my requireTrue((user id of item 1 of usersFound) is "7", "user list")
  my requireTrue((is bot of item 1 of usersFound) is true, "bot profile field")
  set knownUsers to find users "@Fixture" in space "7" maximum count 1 start offset 0
  my requireTrue((display name of item 1 of knownUsers) is "Fixture 🦊", "cached user search")
  my requireTrue((user id of (user info "9223372036854775807")) is "9223372036854775807", "user ID lookup")
  set publicUsers to search public users "@fixture" maximum count 1
  my requireTrue((username of item 1 of publicUsers) is "fixture", "public discovery")
  set createdThread to create thread "Fixture workflow" in space "7" participant ids {"7", "9223372036854775807", "7"}
  set destination to chat id of createdThread
  my requireTrue(destination is "43", "thread creation")
  set firstMessage to send message "**Hello** [@Fixture](inline://user/7)." to chat destination request id "12345"
  my requireTrue((chat id of firstMessage) is destination, "create then send Markdown with a mention")
  my requireTrue((send request id of firstMessage) is "12345", "first message retry ID")
  set publicThread to create thread "Public fixture" in space "7" publicly visible true
  my requireTrue((chat id of publicThread) is "44", "public thread boolean")
  my requireTrue((chat id of (create thread)) is "43", "untitled self-only thread")
  set chatsFound to list chats in space "7" maximum count 1 start offset 0
  my requireTrue((chat id of item 1 of chatsFound) is "42", "chats")
  my requireTrue((unread count of item 1 of chatsFound) is 2, "integer field")
  set matches to find chats "Fixture" maximum count 10
  my requireTrue((count of matches) is 1, "find")
  my requireTrue((count of (find chats "empty")) is 0, "empty list")
  my requireTrue((open chat "9223372036854775807") is "9223372036854775807", "open ID precision")
  my requireTrue((chat id of (current chat)) is "9223372036854775807", "selection")
  set history to recent messages "42" maximum count 1 before message "100"
  my requireTrue((message text of item 1 of history) is "Hello 🦊", "messages")
  my requireTrue((outgoing of item 1 of history) is false, "boolean field")
  my requireTrue((sent at of item 1 of history) is 1700000000, "timestamp seconds")
  set receipt to send message "Fixture only" to chat "42" request id "9223372036854775807"
  my requireTrue((message id of receipt) is "100", "async receipt")
  my requireTrue((send request id of receipt) is "9223372036854775807", "request ID precision")
  my requireTrue((chat link "42") is "in://chat/42", "link")
  set rejected to false
  try
    open chat "0"
  on error errorText number errorNumber
    set rejected to errorNumber is -1700
  end try
  my requireTrue(rejected, "invalid ID error")
  set rejected to false
  try
    recent messages "42" maximum count 101
  on error errorText number errorNumber
    set rejected to errorNumber is -1700
  end try
  my requireTrue(rejected, "limit error")
  set rejected to false
  try
    find chats "failure"
  on error errorText number errorNumber
    set rejected to errorNumber is -10004
  end try
  my requireTrue(rejected, "async error reply")
  set rejected to false
  try
    create thread "Invalid" publicly visible true
  on error errorText number errorNumber
    set rejected to errorNumber is -1700
  end try
  my requireTrue(rejected, "public Home thread rejected")
  set rejected to false
  try
    create thread "Invalid" in space "7" publicly visible true participant ids {"7"}
  on error errorText number errorNumber
    set rejected to errorNumber is -1700
  end try
  my requireTrue(rejected, "public participants rejected")
end tell
return "PASS: fifteen commands, thread participants, create-then-send Markdown, user discovery, native values, and errors"
'''.replace("BUNDLE_PATH", str(bundle).replace("\\", "\\\\").replace('"', '\\"'))

log = package / ".build" / "fixture.log"
# Launch Services must own the instance or AppleScript can launch a second copy.
launcher = subprocess.Popen(["open", "-n", "-W", str(bundle), "--stdout", str(log), "--stderr", str(log)])
try:
    for _ in range(50):
        if fixture_pids():
            break
        time.sleep(0.1)
    result = subprocess.run(["osascript", "-"], input=script, text=True, capture_output=True, timeout=45)
    print(result.stdout.strip())
    if result.returncode:
        raise SystemExit(result.stderr.strip())
except subprocess.TimeoutExpired:
    raise SystemExit("Automation timed out. Check the macOS consent prompt for InlineScriptingFixture, then rerun.")
finally:
    # Existing instances were rejected; these exact-executable PIDs belong to this test.
    for pid in fixture_pids():
        os.kill(pid, signal.SIGTERM)
    launcher.wait(timeout=10)

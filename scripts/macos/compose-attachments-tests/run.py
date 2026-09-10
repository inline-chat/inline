#!/usr/bin/env python3
"""Compile production AppKit attachment views and run a local, network-free UI check."""
import pathlib
import subprocess
import tempfile

here = pathlib.Path(__file__).resolve().parent
root = here.parents[2]
output = pathlib.Path(tempfile.mkdtemp(prefix="inline-compose-attachments-"))
sources = [here / "Fixtures.swift"] + [
    root / "apple/InlineMac/Views/Compose" / name
    for name in ("ComposeAttachments.swift", "ImageAttachment.swift", "VideoAttachmentView.swift")
] + [here / "main.swift"]
# The fixture file supplies the small InlineKit model/service surface.
source = "\n".join(p.read_text().replace("import InlineKit\n", "") for p in sources)
(output / "main.swift").write_text(source)
print(f"Artifacts: {output}", flush=True)
subprocess.run(["xcrun", "swiftc", str(output / "main.swift"), "-o", str(output / "check")], check=True)
with (output / "run.log").open("w") as log:
    result = subprocess.run([str(output / "check"), str(output)], stdout=log, stderr=subprocess.STDOUT)
log_text = (output / "run.log").read_text()
for line in log_text.splitlines():
    if any(term in line for term in ("PASS:", "sample", "failed", "EMPTY:")):
        print(line)
geometry_failure = any(term in log_text for term in (
    "not defined because", "Unable to simultaneously satisfy", "out-of-bounds indexPath",
))
if geometry_failure:
    print("FAIL: AppKit reported invalid collection geometry; inspect run.log")
raise SystemExit(result.returncode or int(geometry_failure))

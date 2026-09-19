#!/usr/bin/env python3
"""Run the production macOS editor locally, without app state or network access."""
import pathlib
import subprocess
import tempfile

here = pathlib.Path(__file__).resolve().parent
root = here.parents[2]
output = pathlib.Path(tempfile.mkdtemp(prefix="inline-compose-scroll-"))
sources = [here / "Fixtures.swift"] + [
    root / "apple/InlineMac" / path
    for path in (
        "Views/Compose/ComposeControlMode.swift",
        "Views/Compose/ComposeScrollView.swift",
        "Utils/LineHeight.swift",
        "Views/Compose/ComposeTextEditor.swift",
    )
] + [here / "main.swift"]
source = "\n".join(path.read_text() for path in sources)
for module in ("InlineKit", "Logger", "TextProcessing"):
    source = source.replace(f"import {module}\n", "")
(output / "main.swift").write_text(source)
print(f"Artifacts: {output}", flush=True)
subprocess.run(["xcrun", "swiftc", str(output / "main.swift"), "-o", str(output / "check")], check=True)
subprocess.run([str(output / "check")], check=True)

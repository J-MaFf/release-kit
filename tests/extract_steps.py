"""Writes each pwsh `run:` step of a workflow job to <out>/<step-id>.ps1."""
import pathlib
import sys

import yaml

workflow, job, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
steps = yaml.safe_load(pathlib.Path(workflow).read_text(encoding="utf-8"))["jobs"][job]["steps"]
for step in steps:
    if step.get("shell") == "pwsh" and "id" in step:
        (out / f"{step['id']}.ps1").write_text(step["run"], encoding="utf-8")
        print(step["id"])
    elif step.get("shell") == "pwsh":
        name = step["name"].lower().replace(" ", "-")
        (out / f"{name}.ps1").write_text(step["run"], encoding="utf-8")
        print(name)

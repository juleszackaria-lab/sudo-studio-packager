#!/usr/bin/env python3
"""P60-D: static validation of the Linux workflows and of the container script.

This does NOT replace a CI run: it only refuses the workflow files that could
never prove anything (missing container matrix, no offline phase, one CPU
variant only, no gate). It runs locally and in CI before the expensive jobs.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github" / "workflows"
fails = []
checks = 0


def ok(cond, label):
    global checks
    checks += 1
    if cond:
        print(f"OK   {label}")
    else:
        fails.append(label)
        print(f"FAIL {label}")


def load(name):
    p = WF / name
    if not p.exists():
        fails.append(f"{name} absent")
        print(f"FAIL {name} absent")
        return None
    return yaml.safe_load(p.read_text(encoding="utf-8"))


smoke_raw = (WF / "05-linux-smoke.yml").read_text(encoding="utf-8") if (WF / "05-linux-smoke.yml").exists() else ""
smoke = load("05-linux-smoke.yml")
pkg = load("04-package-linux.yml")
script = (ROOT / "linux" / "container-test.sh").read_text(encoding="utf-8") if (ROOT / "linux" / "container-test.sh").exists() else ""

print("== 05 - Linux smoke test ==")
if smoke:
    jobs = smoke.get("jobs", {})
    ok("smoke" in jobs, "05 a un job de matrice 'smoke'")
    cells = (jobs.get("smoke", {}).get("strategy", {}).get("matrix", {}) or {}).get("include", []) or []
    ok(len(cells) >= 6, f"05 couvre au moins 6 cellules de conteneurs (trouve {len(cells)})")
    images = [str(c.get("image", "")) for c in cells]
    for need in ["ubuntu:22.04", "ubuntu:24.04", "debian:12", "rockylinux:9"]:
        ok(any(i.startswith(need) for i in images), f"05 teste {need}")
    ok(any("fedora" in i for i in images), "05 teste fedora (.rpm)")
    ok(any(i.endswith("slim") for i in images), "05 a un conteneur MINIMAL pour le .tar.gz")
    ok(any(c.get("pkg_type") == "tar" for c in cells), "05 installe aussi le .tar.gz")
    ok(any(c.get("pkg_type") == "deb" for c in cells) and any(c.get("pkg_type") == "rpm" for c in cells),
       "05 couvre les deux formats natifs")
    variants = {str(c.get("variant")) for c in cells}
    ok({"avx2", "compat"} <= variants, f"05 teste les DEUX variantes CPU (trouve {sorted(variants)})")
    ok("--network none" in smoke_raw, "05 a une phase hors ligne (--network none)")
    ok("--offline" in smoke_raw, "05 appelle le script en mode --offline")
    ok("docker commit" in smoke_raw, "05 reutilise l arbre installe via docker commit")
    ok("download-artifact@v4" in smoke_raw and "run-id:" in smoke_raw, "05 telecharge les artefacts d un run precis")
    ok("smoke-gate" in jobs, "05 a une porte finale")
    gate = jobs.get("smoke-gate", {})
    ok("smoke" in (gate.get("needs") or []), "la porte depend de toutes les cellules")
    ok("invalidat" not in smoke_raw, "aucune invalidation de cache deguisee")
    ok("windows-non-regression" in jobs, "05 verifie la non-regression Windows 01/02/03")
    # PyYAML reads the 'on' key as the boolean True (YAML 1.1).
    triggers = smoke.get("on", smoke.get(True, {}))
    ok("workflow_call" in (triggers or {}), "05 est appelable depuis 04 (workflow_call)")

print("== 04 - Package Linux ==")
if pkg:
    jobs = pkg.get("jobs", {})
    for name, job in jobs.items():
        runs = job.get("runs-on")
        if runs and not str(runs).startswith("${{"):
            ok(runs == "ubuntu-22.04", f"04 job '{name}' tourne sur ubuntu-22.04 (glibc de reference)")
    ok("linux-smoke" in jobs, "04 appelle le smoke test")
    ok("linux-delivery-decision" in jobs, "04 a une decision finale de livraison")
    raw04 = (WF / "04-package-linux.yml").read_text(encoding="utf-8")
    ok("AUCUN artefact n est livrable" in raw04, "la decision finale dit qu un rouge interdit la livraison")
    ok("--list-extensions" in raw04, "le critere dur P47 est conserve")
    for name in ["SudoStudio-Linux-Tar", "SudoStudio-Linux-Deb", "SudoStudio-Linux-Rpm"]:
        ok(name in raw04, f"04 publie l artefact {name}")

print("== linux/container-test.sh ==")
for marker, label in [
    ("--network none", "aucune dependance a --network none dans le script (c est le workflow qui isole)"),
    ("license", "le script verifie la licence"),
    ("/v1/chat/completions", "le script interroge /v1/chat/completions"),
    ("ELECTRON_RUN_AS_NODE=1", "le script lance l agent via ELECTRON_RUN_AS_NODE"),
    ("approvals", "le script passe par l approbation explicite"),
    ("journal", "le script verifie les journaux"),
    ("desinstallation", "le script verifie la desinstallation"),
    ("RESULTAT", "le script imprime un verdict final"),
]:
    if marker == "--network none":
        ok(marker not in script, label)
    else:
        ok(marker in script, label)
ok('aucun acces reseau' in script, "le script prouve lui-meme l absence de reseau en phase 2")
failed_checks = [
    chk for chk in (
        "l agent a cree hello-linux.txt",
        "modele charge",
        "runtime repond sur /health",
        "backend repond sur /api/system/health",
    ) if chk not in script
]
ok(not failed_checks, f"les 4 verifications coeur existent ({failed_checks or 'toutes presentes'})")

print()
print(f"== {checks - len(fails)}/{checks} verifications OK, {len(fails)} FAIL ==")
for f in fails:
    print(f"  - {f}")
sys.exit(1 if fails else 0)

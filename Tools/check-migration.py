#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check ongoing SwiftPM source membership without a frozen migration snapshot.

TurnOverCore discovers its shared Core, Views and System folders; app files are explicit.
Every Swift source under Sources needs one target or an explicitly excluded sample folder.
Shared Experiments stay outside every default target.
"""
import argparse
import copy
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SHARED_FOLDERS = {"Core", "Views", "System"}
NONPRODUCTION = {"Tests", "Experiments", "Fixtures"}
SOURCE_SUFFIXES = {".swift", ".m", ".c", ".mm", ".cpp"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def relative(path):
    require(isinstance(path, str) and bool(path), "source path must be a nonempty string")
    p = PurePosixPath(path)
    require(not p.is_absolute() and ".." not in p.parts, f"unsafe repository path: {path!r}")
    return p.as_posix()


def toolchain_environment():
    # Match build.sh when xcode-select still points to Command Line Tools. An explicitly
    # selected working Xcode is preserved; the manifest requires the full macOS SDK.
    env = os.environ.copy()
    selected = subprocess.run(["xcodebuild", "-version"], env=env, capture_output=True, timeout=15)
    if selected.returncode != 0:
        for name in ("Xcode.app", "Xcode-beta.app"):
            developer = Path("/Applications") / name / "Contents/Developer"
            if (developer / "usr/bin/xcodebuild").is_file():
                env["DEVELOPER_DIR"] = str(developer)
                break
        else:
            raise ValueError("Full Xcode is required; set DEVELOPER_DIR to its Contents/Developer directory")
    return env


def metadata(kind, supplied, env):
    if supplied:
        require(supplied.stat().st_size <= 8 * 1024 * 1024, f"metadata too large: {supplied}")
        return json.loads(supplied.read_text())
    command = ["swift", "package", "--package-path", str(ROOT)]
    if env.get("TURNOVER_BUILD"):
        command += ["--scratch-path", env["TURNOVER_BUILD"]]
    command += ["describe", "--type", "json"] if kind == "resolved" else ["dump-package"]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
    require(result.returncode == 0, f"SwiftPM {kind} failed: {result.stderr[-2000:].strip()}")
    require(len(result.stdout) <= 8 * 1024 * 1024, "SwiftPM metadata too large")
    return json.loads(result.stdout)


def targets(package):
    items = package["targets"]
    names = [item["name"] for item in items]
    require(len(set(names)) == len(names), "duplicate target name")
    return {item["name"]: item for item in items}


def source_paths(target):
    return [relative(str(PurePosixPath(target["path"]) / relative(name)))
            for name in target.get("sources", [])]


def app_production(path):
    parts = PurePosixPath(path).parts
    return parts[:2] == ("Sources", "Apps") and not (set(parts[2:-1]) & NONPRODUCTION)


def shared_production(path):
    parts = PurePosixPath(path).parts
    return (len(parts) >= 3 and parts[0] == "Sources" and parts[1] in SHARED_FOLDERS
            and not (set(parts[2:-1]) & NONPRODUCTION))


def is_excluded(path, exclusions):
    return any(PurePosixPath(path).is_relative_to(folder) for folder in exclusions)


def shared_note_message(path):
    entry = PurePosixPath(path).relative_to("Sources").as_posix()
    return (f"non-code file in shared source folder: {path}; add {entry!r} to TurnOverCore's "
            "excludes in Package.swift or move the note to docs")


def source_membership(root, resolved, manifest):
    actual, declared = targets(resolved), targets(manifest)
    require(set(actual) == set(declared), "resolved and declared target names differ")
    core = declared.get("TurnOverCore")
    require(core is not None and core["path"] == "Sources", "TurnOverCore must retain the Sources anchor")
    require(isinstance(core.get("sources"), list), "TurnOverCore requires shared folders and explicit app files")
    core_entries = [relative(p) for p in core["sources"]]
    for folder in sorted(SHARED_FOLDERS):
        require(core_entries.count(folder) == 1, f"Core sources must contain exactly one {folder} folder entry")
        require((root / "Sources" / folder).is_dir(), f"shared source folder missing: {folder}")
    for name, item in declared.items():
        raw = item.get("sources")
        if raw is not None:
            normal = [relative(p) for p in raw]
            require(len(normal) == len(set(normal)), f"duplicate source entries in {name}")
            require(all((name == "TurnOverCore" and p in SHARED_FOLDERS) or
                        PurePosixPath(p).suffix in SOURCE_SUFFIXES for p in normal),
                    f"only TurnOverCore's shared folder entries may name source folders: {name}")
    apps = {"Sources/" + p for p in core_entries if p not in SHARED_FOLDERS}
    require(all(app_production(p) and PurePosixPath(p).suffix == ".swift" for p in apps),
            "Core entries outside its shared folders must be production Apps Swift files")
    expected_apps = {p.relative_to(root).as_posix() for p in (root / "Sources/Apps").rglob("*.swift")
                     if app_production(p.relative_to(root).as_posix())}
    require(apps == expected_apps,
            f"app source list differs: missing={sorted(expected_apps-apps)}, extra={sorted(apps-expected_apps)}")
    exclusions = {
        name: [PurePosixPath(relative(actual[name]["path"])) / relative(path)
               for path in item.get("exclude", [])]
        for name, item in declared.items()
    }
    for folder in sorted(SHARED_FOLDERS):
        for file in sorted((root / "Sources" / folder).rglob("*")):
            if not file.is_file() or file.suffix in SOURCE_SUFFIXES | {".h", ".hpp"}:
                continue
            path = file.relative_to(root).as_posix()
            # SwiftPM ignores hidden metadata such as Finder's .DS_Store and hidden note folders.
            # This exception is only for non-code; the Swift inventory below still checks hidden sources.
            if any(part.startswith(".") for part in PurePosixPath(path).parts):
                continue
            require(is_excluded(path, exclusions["TurnOverCore"]), shared_note_message(path))
    owners = {}
    compiled_paths = set()
    for name, item in actual.items():
        for path in source_paths(item):
            file = root / path
            require(file.is_file(), f"resolved source missing: {path}")
            canonical = file.resolve()
            require(canonical.is_relative_to(root.resolve()), f"resolved source escapes the repository: {path}")
            require(canonical not in owners, f"source compiled more than once: {path}")
            owners[canonical] = name
            compiled_paths.add(path)
            parts = PurePosixPath(path).parts
            if len(parts) >= 2 and parts[0] == "Sources" and parts[1] in SHARED_FOLDERS:
                require(file.suffix in SOURCE_SUFFIXES | {".h", ".hpp"}, shared_note_message(path))
            require(parts[:2] != ("Sources", "Experiments"),
                    f"shared experiment compiled into default target {name}: {path}")
            if parts[:2] == ("Sources", "Apps"):
                require(app_production(path), f"app test/experiment/fixture compiled into {name}: {path}")
                require(name == "TurnOverCore", f"app production source belongs to wrong target: {path}")
            elif len(parts) >= 2 and parts[0] == "Sources" and parts[1] in SHARED_FOLDERS:
                require(shared_production(path), f"shared test/experiment/fixture compiled into {name}: {path}")
                require(name == "TurnOverCore", f"shared production source belongs to wrong target: {path}")
    # Another target's whole-root exclusion (for example TurnOverTests in Core) does not
    # intentionally exclude a sample from its own target. Name the sample folder explicitly.
    sample_exclusions = [path for paths in exclusions.values() for path in paths
                         if set(path.parts[1:]) & NONPRODUCTION]
    for file in sorted((root / "Sources").rglob("*.swift")):
        if not file.is_file():
            continue
        path = file.relative_to(root).as_posix()
        sample = bool(set(PurePosixPath(path).parts[1:-1]) & NONPRODUCTION)
        require(path in compiled_paths or (sample and is_excluded(path, sample_exclusions)),
                f"Swift source has no target: {path}; add it to its intended target in Package.swift "
                "or move the sample to an excluded Tests, Experiments or Fixtures folder")
    expected_shared = {p.relative_to(root).as_posix()
                       for folder in SHARED_FOLDERS
                       for p in (root / "Sources" / folder).rglob("*.swift")
                       if shared_production(p.relative_to(root).as_posix())}
    expected = expected_shared | expected_apps
    resolved_core = set(source_paths(actual["TurnOverCore"]))
    require(expected == resolved_core,
            f"Core resolved membership differs: missing={sorted(expected-resolved_core)}, extra={sorted(resolved_core-expected)}")
    return len(resolved_core)


def self_test():
    with tempfile.TemporaryDirectory(prefix="turnover-membership-") as temp:
        root = Path(temp)
        def add(path):
            p = root / "Sources" / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("// public sample\n")
        originals = [f"{folder}/Original.swift" for folder in sorted(SHARED_FOLDERS)]
        originals.append("Apps/Calculator/B.swift")
        expected_count = len(originals)
        for path in originals:
            add(path)
        manifest = {"targets": [{"name": "TurnOverCore", "path": "Sources",
                                 "sources": sorted(SHARED_FOLDERS) + ["Apps/Calculator/B.swift"]}]}
        resolved = copy.deepcopy(manifest)
        resolved["targets"][0]["sources"] = list(originals)
        require(source_membership(root, resolved, manifest) == expected_count, "valid shared folders and app file rejected")
        for folder in sorted(SHARED_FOLDERS):
            path = f"{folder}/New.swift"
            add(path)
            resolved["targets"][0]["sources"].append(path)
        expected_count += len(SHARED_FOLDERS)
        require(source_membership(root, resolved, manifest) == expected_count, "shared folder growth should need no manifest edit")
        failures = []
        def refuses(label, current, declaration, message=None):
            try:
                source_membership(root, current, declaration)
            except ValueError as error:
                if message is not None:
                    require(message in str(error), f"{label}: unexpected diagnostic: {error}")
                failures.append(label)
            else:
                raise AssertionError(f"invalid source membership accepted: {label}")
        invalid_entries = [f"./{folder}" for folder in sorted(SHARED_FOLDERS)]
        invalid_entries += [f"{folder}/Subfolder" for folder in sorted(SHARED_FOLDERS)]
        invalid_entries += [f"{folder}/New.swift" for folder in sorted(SHARED_FOLDERS)]
        invalid_entries += ["./Apps/Calculator/B.swift", "Apps/Calculator", "TurnOverCore",
                            "Sources", "../Outside.swift", "/Outside.swift"]
        for entry in invalid_entries:
            bad = copy.deepcopy(manifest); bad["targets"][0]["sources"].append(entry)
            refuses(f"invalid manifest entry {entry}", resolved, bad)
        for folder in sorted(SHARED_FOLDERS):
            missing = copy.deepcopy(manifest); missing["targets"][0]["sources"].remove(folder)
            refuses(f"missing shared folder {folder}", resolved, missing)
        missing_app = copy.deepcopy(manifest); missing_app["targets"][0]["sources"].pop()
        refuses("missing explicit app file", resolved, missing_app)
        for source in originals:
            missing = copy.deepcopy(resolved); missing["targets"][0]["sources"].remove(source)
            refuses(f"source omitted from resolved target: {source}", missing, manifest)
        for parent in sorted(SHARED_FOLDERS) + ["Apps/Calculator"]:
            for folder in sorted(NONPRODUCTION):
                path = f"{parent}/{folder}/Sample.swift"
                add(path)
                manifest["targets"][0].setdefault("exclude", []).append(f"{parent}/{folder}")
                # Samples remain excluded even when a recursive shared folder discovers its neighbours.
                require(source_membership(root, resolved, manifest) == expected_count, f"excluded {path} affected production")
                compiled = copy.deepcopy(resolved); compiled["targets"][0]["sources"].append(path)
                bad = copy.deepcopy(manifest)
                if parent.startswith("Apps/"):
                    bad["targets"][0]["sources"].append(path)
                refuses(f"compiled nonproduction source {path}", compiled, bad)
            path = f"{parent}/README.md"
            add(path)
            manifest["targets"][0].setdefault("exclude", []).append(path)
            compiled = copy.deepcopy(resolved); compiled["targets"][0]["sources"].append(path)
            refuses(f"compiled documentation {path}", compiled, manifest)
        for source in originals:
            overlap = copy.deepcopy(resolved)
            overlap["targets"].append({"name": "Other", "path": "Sources", "sources": [source]})
            overlap_manifest = copy.deepcopy(manifest); overlap_manifest["targets"].append(overlap["targets"][-1])
            refuses(f"source compiled by two targets: {source}", overlap, overlap_manifest)
            wrong = copy.deepcopy(resolved); wrong["targets"][0]["sources"].remove(source)
            wrong["targets"].append({"name": "Other", "path": "Sources", "sources": [source]})
            wrong_manifest = copy.deepcopy(manifest); wrong_manifest["targets"].append(wrong["targets"][-1])
            refuses(f"wrong target for source: {source}", wrong, wrong_manifest)
        experiment = "Experiments/Sample.swift"
        add(experiment)
        manifest["targets"][0].setdefault("exclude", []).append("Experiments")
        require(source_membership(root, resolved, manifest) == expected_count,
                "excluded shared experiment affected production")
        for name in ("TurnOverCore", "Other"):
            compiled = copy.deepcopy(resolved)
            declaration = copy.deepcopy(manifest)
            if name == "TurnOverCore":
                compiled["targets"][0]["sources"].append(experiment)
            else:
                target = {"name": name, "path": "Sources", "sources": [experiment]}
                compiled["targets"].append(target)
                declaration["targets"].append(copy.deepcopy(target))
            refuses(f"shared experiment compiled into {name}", compiled, declaration)
        for path in ("TurnOverCore/Phrases.swift", "Unlisted/Feature.swift", "Root.swift",
                     "TurnOverProbe/NewGate.swift", "Core/.drafts/Hidden.swift"):
            add(path)
            refuses(f"orphan Swift source {path}", resolved, manifest,
                    f"Swift source has no target: Sources/{path}")
            excluded = copy.deepcopy(manifest)
            excluded["targets"][0].setdefault("exclude", []).append(path)
            refuses(f"production exclusion cannot hide orphan {path}", resolved, excluded,
                    f"Swift source has no target: Sources/{path}")
            (root / "Sources" / path).unlink()
        for folder in sorted(NONPRODUCTION):
            parent = f"Unlisted/{folder}"
            path = f"{parent}/Sample.swift"
            add(path)
            refuses(f"sample folder needs exclusion {path}", resolved, manifest,
                    f"Swift source has no target: Sources/{path}")
            broad_exclusion = copy.deepcopy(manifest)
            broad_exclusion["targets"][0].setdefault("exclude", []).append("Unlisted")
            refuses(f"whole-root exclusion cannot hide sample {path}", resolved, broad_exclusion,
                    f"Swift source has no target: Sources/{path}")
            manifest["targets"][0].setdefault("exclude", []).append(parent)
            require(source_membership(root, resolved, manifest) == expected_count,
                    f"intentional excluded sample rejected: {path}")
        for folder in sorted(SHARED_FOLDERS):
            for hidden in (".DS_Store", "Keys/.notes/draft.md"):
                path = f"{folder}/{hidden}"
                add(path)
                require(source_membership(root, resolved, manifest) == expected_count,
                        f"SwiftPM-ignored metadata rejected: {path}")
            path = f"{folder}/Keys/NOTES.md"
            add(path)
            diagnostic = "excludes in Package.swift or move the note to docs"
            refuses(f"unhandled shared note {path}", resolved, manifest, diagnostic)
            compiled = copy.deepcopy(resolved); compiled["targets"][0]["sources"].append(path)
            refuses(f"resolved shared note {path}", compiled, manifest, diagnostic)
            manifest["targets"][0].setdefault("exclude", []).append(path)
            require(source_membership(root, resolved, manifest) == expected_count,
                    f"excluded shared note rejected: {path}")
        # Real test and probe targets keep their sources; a folder's name is not a frozen target inventory.
        for name in ("TurnOverTests", "TurnOverProbe", "NewDiagnostic"):
            path = f"{name}/Check.swift"
            add(path)
            target = {"name": name, "path": f"Sources/{name}", "sources": ["Check.swift"]}
            resolved["targets"].append(copy.deepcopy(target))
            manifest["targets"].append(copy.deepcopy(target))
            require(source_membership(root, resolved, manifest) == expected_count,
                    f"registered diagnostic target rejected: {name}")
        add("Apps/Calculator/New.swift")
        refuses("new app file must be listed explicitly", resolved, manifest)
        manifest["targets"][0]["sources"].append("Apps/Calculator/New.swift")
        resolved["targets"][0]["sources"].append("Apps/Calculator/New.swift")
        expected_count += 1
        require(source_membership(root, resolved, manifest) == expected_count, "explicit new app file rejected")
        print(f"membership self-test: {len(failures)} invalid changes rejected; shared folder growth, explicit app files and excluded samples accepted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-json", type=Path, help="precomputed swift package describe --type json")
    parser.add_argument("--dump-json", type=Path, help="precomputed swift package dump-package")
    parser.add_argument("--membership-only", action="store_true", help="check ongoing membership (also the default)")
    parser.add_argument("--self-test", action="store_true", help="run isolated checker regressions only")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    env = toolchain_environment() if not (args.package_json and args.dump_json) else os.environ.copy()
    count = source_membership(ROOT, metadata("resolved", args.package_json, env), metadata("manifest", args.dump_json, env))
    print(f"source membership: {count} TurnOverCore files, no omissions, duplicates or compiled tests/experiments/fixtures")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"membership check failed: {error}", file=sys.stderr)
        sys.exit(1)

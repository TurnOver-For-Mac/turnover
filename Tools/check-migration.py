#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check ongoing SwiftPM source membership without a frozen migration snapshot.

TurnOverCore discovers its own folder normally; app production files are explicit.
App Tests, Experiments and Fixtures remain outside the reader's build.
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


def source_membership(root, resolved, manifest):
    actual, declared = targets(resolved), targets(manifest)
    require(set(actual) == set(declared), "resolved and declared target names differ")
    core = declared.get("TurnOverCore")
    require(core is not None and core["path"] == "Sources", "TurnOverCore must retain the Sources anchor")
    require(isinstance(core.get("sources"), list), "TurnOverCore requires Core's folder and explicit app files")
    core_entries = [relative(p) for p in core["sources"]]
    require(core_entries.count("TurnOverCore") == 1, "Core sources must contain exactly one TurnOverCore folder entry")
    for name, item in declared.items():
        raw = item.get("sources")
        if raw is not None:
            normal = [relative(p) for p in raw]
            require(len(normal) == len(set(normal)), f"duplicate source entries in {name}")
            require(all((name == "TurnOverCore" and p == "TurnOverCore") or
                        PurePosixPath(p).suffix in SOURCE_SUFFIXES for p in normal),
                    f"only Core's TurnOverCore entry may name a source folder: {name}")
    apps = {"Sources/" + p for p in core_entries if p != "TurnOverCore"}
    require(all(app_production(p) and PurePosixPath(p).suffix == ".swift" for p in apps),
            "Core entries outside its folder must be production Apps Swift files")
    expected_apps = {p.relative_to(root).as_posix() for p in (root / "Sources/Apps").rglob("*.swift")
                     if app_production(p.relative_to(root).as_posix())}
    require(apps == expected_apps,
            f"app source list differs: missing={sorted(expected_apps-apps)}, extra={sorted(apps-expected_apps)}")
    owners = {}
    for name, item in actual.items():
        for path in source_paths(item):
            file = root / path
            require(file.is_file(), f"resolved source missing: {path}")
            canonical = file.resolve()
            require(canonical.is_relative_to(root.resolve()), f"resolved source escapes the repository: {path}")
            require(canonical not in owners, f"source compiled more than once: {path}")
            owners[canonical] = name
            if path.startswith("Sources/Apps/"):
                require(app_production(path), f"app test/experiment/fixture compiled into {name}: {path}")
                require(name == "TurnOverCore", f"app production source belongs to wrong target: {path}")
    expected_core = {p.relative_to(root).as_posix() for p in (root / "Sources/TurnOverCore").rglob("*.swift")}
    expected = expected_core | expected_apps
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
        add("TurnOverCore/A.swift"); add("Apps/Calculator/B.swift")
        manifest = {"targets": [{"name": "TurnOverCore", "path": "Sources",
                                 "sources": ["TurnOverCore", "Apps/Calculator/B.swift"]}]}
        resolved = copy.deepcopy(manifest)
        resolved["targets"][0]["sources"][0] = "TurnOverCore/A.swift"
        require(source_membership(root, resolved, manifest) == 2, "valid folder and app file rejected")
        add("TurnOverCore/New.swift")
        resolved["targets"][0]["sources"].append("TurnOverCore/New.swift")
        require(source_membership(root, resolved, manifest) == 3, "new Core file should need no manifest edit")
        failures = 0
        def refuses(current, declaration):
            nonlocal failures
            try:
                source_membership(root, current, declaration)
            except ValueError:
                failures += 1
            else:
                raise AssertionError("invalid source membership accepted")
        for entry in ("./TurnOverCore", "./Apps/Calculator/B.swift", "Apps/Calculator", "../Outside.swift"):
            bad = copy.deepcopy(manifest); bad["targets"][0]["sources"].append(entry)
            refuses(resolved, bad)
        missing_folder = copy.deepcopy(manifest); missing_folder["targets"][0]["sources"].remove("TurnOverCore")
        refuses(resolved, missing_folder)
        missing_app = copy.deepcopy(manifest); missing_app["targets"][0]["sources"].pop()
        refuses(resolved, missing_app)
        for source in ("TurnOverCore/A.swift", "Apps/Calculator/B.swift"):
            missing = copy.deepcopy(resolved); missing["targets"][0]["sources"].remove(source)
            refuses(missing, manifest)
        for folder in sorted(NONPRODUCTION):
            path = f"Apps/Calculator/{folder}/Sample.swift"
            add(path)
            # Unlisted samples remain excluded; listing one cannot make it production.
            require(source_membership(root, resolved, manifest) == 3, f"excluded {folder} sample affected production")
            bad = copy.deepcopy(manifest); bad["targets"][0]["sources"].append(path)
            compiled = copy.deepcopy(resolved); compiled["targets"][0]["sources"].append(path)
            refuses(compiled, bad)
        overlap = copy.deepcopy(resolved)
        overlap["targets"].append({"name": "Other", "path": "Sources", "sources": ["TurnOverCore/A.swift"]})
        overlap_manifest = copy.deepcopy(manifest); overlap_manifest["targets"].append(overlap["targets"][-1])
        refuses(overlap, overlap_manifest)
        wrong = copy.deepcopy(resolved); wrong["targets"][0]["sources"].remove("Apps/Calculator/B.swift")
        wrong["targets"].append({"name": "Other", "path": "Sources", "sources": ["Apps/Calculator/B.swift"]})
        wrong_manifest = copy.deepcopy(manifest); wrong_manifest["targets"].append(wrong["targets"][-1])
        refuses(wrong, wrong_manifest)
        require(failures == 13, "self-test count changed unexpectedly")
        print(f"membership self-test: {failures} invalid changes rejected; folder growth and excluded samples accepted")


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
    print(f"source membership: {count} Core files, no omissions, duplicates or compiled app tests/experiments/fixtures")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"membership check failed: {error}", file=sys.stderr)
        sys.exit(1)

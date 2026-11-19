// SPDX-License-Identifier: GPL-3.0-or-later
// Reading an add-on's Python without running it (docs/PLUGIN-PLATFORM-PLAN.md, stage A, point 3). The script below is a
// resource string written to a temporary file and run as `/usr/bin/python3 -I <script> <file>`, with a timeout. It only
// calls ast.parse and prints JSON: nothing from the add-on is imported, compiled or executed.
import Foundation
import TurnOverCore

nonisolated public struct ConvertArg: Codable, Sendable { public var k: String; public var v: String? }
nonisolated public struct ConvertCall: Codable, Sendable { public var name: String?; public var args: [ConvertArg]; public var kwargs: [String?] }
nonisolated public struct ConvertStmt: Codable, Sendable {
    public var line: Int; public var endLine: Int; public var source: [String]; public var call: ConvertCall?
}
nonisolated public struct ConvertDecorator: Codable, Sendable {
    public var name: String?; public var description: String?; public var gesture: String?; public var gestures: [String]?; public var category: String?
}
nonisolated public struct ConvertMethod: Codable, Sendable {
    public var name: String; public var line: Int; public var endLine: Int; public var args: [String]; public var doc: String?
    public var decorators: [ConvertDecorator]; public var calls: [String: Int]; public var refs: [String: Int]; public var patches: [String]
    public var body: [ConvertStmt]; public var bodyTruncated: Bool
}
nonisolated public struct ConvertClass: Codable, Sendable {
    public var name: String; public var bases: [String]; public var line: Int; public var gestures: [String: String]; public var methods: [ConvertMethod]
}
nonisolated public struct ConvertFileAnalysis: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var imports: [String]?
    public var classes: [ConvertClass]?
    public var calls: [String: Int]?
    public var refs: [String: Int]?
    public var patches: [String]?
    public var lines: Int?
}

nonisolated public final class ConvertParse {
    public let directory: URL
    private let script: URL

    /// Writes the parsing script into a new temporary folder (removed by `finish`).
    public init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("turnover-convert-parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("parse.py")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
    }

    public func finish() { try? FileManager.default.removeItem(at: directory) }

    public static let python = "/usr/bin/python3"
    public static let missingMessage = "Python 3 is not installed on this Mac, and the converter needs it to read an add-on's code without running it. It comes with Apple's command line developer tools; install those (xcode-select --install), then run this again. Nothing was converted."

    /// Whether /usr/bin/python3 can parse. Nil when it can; otherwise the plain-words reason to stop.
    public static func problem() -> String? {
        guard FileManager.default.isExecutableFile(atPath: python) else { return missingMessage }
        guard let probe = try? ConvertParse() else { return missingMessage }
        defer { probe.finish() }
        let out = Self.run(arguments: ["-I", "-c", "import ast, json, sys; print('ok')"], in: probe.directory, timeout: 20)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" ? nil : missingMessage
    }

    /// Analyses one file. Never runs it.
    public func analyse(_ file: URL) -> ConvertFileAnalysis {
        guard let text = Self.run(arguments: ["-I", script.path, file.path], in: directory, timeout: 20),
              let analysis = try? JSONDecoder().decode(ConvertFileAnalysis.self, from: Data(text.utf8)) else {
            return ConvertFileAnalysis(ok: false, error: "it could not be read (the Python reader gave no answer in 20 seconds, or an answer that could not be understood)")
        }
        return analysis
    }

    /// Runs python with a timeout; stdout goes to a file so a large answer cannot fill a pipe. Nil on failure or timeout.
    static func run(arguments: [String], in directory: URL, timeout: TimeInterval) -> String? {
        let output = directory.appendingPathComponent("out-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); usleep(200_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        guard let data = PluginFormat.readBounded(output, limit: 16 * 1024 * 1024), data.count <= 16 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The script. It parses; it does not import, compile, execute or evaluate anything it reads.
    static let source = #"""
import ast, json, re, sys

GETTEXT = ("_", "gettext", "pgettext", "ngettext", "npgettext")
MAX_BYTES = 4 * 1024 * 1024
MAX_STMTS = 200

def const(n):
    if isinstance(n, ast.Constant) and isinstance(n.value, str):
        return n.value
    if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
        a, b = const(n.left), const(n.right)
        return a + b if a is not None and b is not None else None
    if isinstance(n, ast.Call) and n.args and not n.keywords and isinstance(n.func, ast.Name) and n.func.id in GETTEXT:
        for a in reversed(n.args):
            c = const(a)
            if c is not None:
                return c
        return None
    if isinstance(n, (ast.List, ast.Tuple)):
        items = [const(e) for e in n.elts]
        return items if all(i is not None for i in items) else None
    return None

def chain(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        parts.reverse()
        return parts
    return None

def analyse(path):
    with open(path, "rb") as f:
        raw = f.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        return {"ok": False, "error": "the file is larger than 4 MB"}
    src = raw.decode("utf-8-sig")
    tree = ast.parse(src, filename="addon.py")
    src_lines = re.split(r"\r\n|\r|\n", src)
    aliases = {}
    imports = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                imports.add(a.name)
                if a.asname:
                    aliases[a.asname] = a.name
                else:
                    root = a.name.split(".")[0]
                    aliases[root] = root
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                continue
            mod = node.module or ""
            imports.add(mod)
            for a in node.names:
                if a.name != "*":
                    aliases[a.asname or a.name] = mod + "." + a.name

    def resolve(parts):
        if parts[0] in aliases:
            return aliases[parts[0]].split(".") + parts[1:], True
        return parts, False

    def call_name(c):
        parts = chain(c.func)
        if parts is None:
            return ("." + c.func.attr) if isinstance(c.func, ast.Attribute) else None
        res, _ = resolve(parts)
        return ".".join(res)

    def argkind(a):
        if isinstance(a, ast.Starred):
            return {"k": "o", "v": None}
        s = const(a)
        if isinstance(s, str):
            return {"k": "s", "v": s}
        if isinstance(a, ast.Constant) and isinstance(a.value, bool):
            return {"k": "b", "v": "true" if a.value else "false"}
        if isinstance(a, ast.Constant) and isinstance(a.value, (int, float)):
            return {"k": "n", "v": repr(a.value)}
        return {"k": "o", "v": None}

    def scan(node):
        calls, refs, patches = {}, {}, []
        inner = set()
        for n in ast.walk(node):
            if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Attribute):
                inner.add(id(n.value))
        for n in ast.walk(node):
            if isinstance(n, ast.Call):
                nm = call_name(n)
                if nm:
                    calls[nm] = calls.get(nm, 0) + 1
            elif isinstance(n, ast.Attribute) and id(n) not in inner:
                parts = chain(n)
                if parts:
                    res, imp = resolve(parts)
                    if imp:
                        k = ".".join(res)
                        refs[k] = refs.get(k, 0) + 1
            if isinstance(n, (ast.Assign, ast.AugAssign, ast.AnnAssign)):
                targets = n.targets if isinstance(n, ast.Assign) else [n.target]
                flat = []
                for t in targets:
                    flat += list(t.elts) if isinstance(t, (ast.Tuple, ast.List)) else [t]
                for t in flat:
                    if isinstance(t, ast.Attribute):
                        parts = chain(t)
                        if parts:
                            res, imp = resolve(parts)
                            if imp:
                                patches.append(".".join(res))
        return calls, refs, sorted(set(patches))

    def deco(d):
        if isinstance(d, ast.Call):
            parts = chain(d.func)
            name = ".".join(resolve(parts)[0]) if parts else None
            kw = {k.arg: k.value for k in d.keywords if k.arg}
            pos = list(d.args)
            def pick(key, idx):
                if key in kw:
                    return const(kw[key])
                return const(pos[idx]) if idx < len(pos) else None
            g = pick("gesture", 2)
            gs = pick("gestures", 3)
            return {"name": name, "description": pick("description", 0) if isinstance(pick("description", 0), str) else None,
                    "gesture": g if isinstance(g, str) else None, "gestures": gs if isinstance(gs, list) else None,
                    "category": pick("category", 1) if isinstance(pick("category", 1), str) else None}
        parts = chain(d)
        return {"name": ".".join(resolve(parts)[0]) if parts else None, "description": None, "gesture": None, "gestures": None, "category": None}

    def stmt(s):
        end = getattr(s, "end_lineno", s.lineno)
        text = src_lines[s.lineno - 1:end]
        indent = s.col_offset
        out = []
        for i, ln in enumerate(text):
            k = 0
            while k < indent and k < len(ln) and ln[k] in " \t":
                k += 1
            out.append(ln[k:] if i else ln[k:])
        if len(out) > 60:
            out = out[:60] + ["... (more lines)"]
        call = None
        v = s.value if isinstance(s, ast.Expr) else None
        if isinstance(v, ast.Call):
            call = {"name": call_name(v), "args": [argkind(a) for a in v.args], "kwargs": [k.arg for k in v.keywords]}
        return {"line": s.lineno, "endLine": end, "source": out, "call": call}

    def method(fn):
        calls, refs, patches = scan(fn)
        body = list(fn.body)
        if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            body = body[1:]
        trunc = len(body) > MAX_STMTS
        return {"name": fn.name, "line": fn.lineno, "endLine": getattr(fn, "end_lineno", fn.lineno),
                "args": [a.arg for a in fn.args.args], "doc": ast.get_docstring(fn),
                "decorators": [deco(d) for d in fn.decorator_list], "calls": calls, "refs": refs, "patches": patches,
                "body": [stmt(s) for s in body[:MAX_STMTS]], "bodyTruncated": trunc}

    classes = []
    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            gestures = {}
            for b in node.body:
                if isinstance(b, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__gestures" for t in b.targets) and isinstance(b.value, ast.Dict):
                    for k, v in zip(b.value.keys, b.value.values):
                        ks = const(k) if k is not None else None
                        vs = const(v)
                        if isinstance(ks, str) and isinstance(vs, str):
                            gestures[ks] = vs
            bases = []
            for b in node.bases:
                parts = chain(b)
                bases.append(".".join(resolve(parts)[0]) if parts else "?")
            classes.append({"name": node.name, "bases": bases, "line": node.lineno, "gestures": gestures,
                            "methods": [method(f) for f in node.body if isinstance(f, (ast.FunctionDef, ast.AsyncFunctionDef))]})
    calls, refs, patches = scan(tree)
    return {"ok": True, "imports": sorted(imports), "classes": classes, "calls": calls, "refs": refs, "patches": patches, "lines": len(src_lines)}

def main():
    try:
        result = analyse(sys.argv[1])
    except SyntaxError as e:
        result = {"ok": False, "error": "it is not valid for the Python on this Mac (3.9) at line %s: %s" % (e.lineno, e.msg)}
    except Exception as e:
        result = {"ok": False, "error": "it could not be read: %s" % type(e).__name__}
    sys.stdout.write(json.dumps(result))

main()
"""#
}

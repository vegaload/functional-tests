#!/usr/bin/env python3
"""Read a case file and an env file. The standard library only."""

import json
import shlex
import sys

AREAS = [
    "http",
    "cli",
    "protocols",
    "websocket",
    "grpc",
    "tcp",
    "udp",
    "mqtt",
    "kafka",
    "postgres",
    "mysql",
    "redis",
    "rabbitmq",
    "ftp",
    "sftp",
    "scenarios",
    "data",
    "reports",
    "import",
    "openapi",
    "doctor",
    "mcp",
    "kubernetes",
]

IDS = [
    "HP-CLI-01", "HP-CLI-02",
    "HP-PROTO-01", "HP-PROTO-02",
    "HP-HTTP-01", "HP-HTTP-02", "HP-HTTP-03",
    "HP-SHAPE-01", "HP-SHAPE-02", "HP-SHAPE-03",
    "HP-WS-01", "HP-GRPC-01", "HP-GRPC-02",
    "HP-TCP-01", "HP-UDP-01",
    "HP-MQTT-01", "HP-MQTT-02", "HP-KAFKA-01", "HP-KAFKA-02",
    "HP-PG-01", "HP-MY-01", "HP-REDIS-01", "HP-RMQ-01",
    "HP-FTP-01", "HP-SFTP-01",
    "HP-SCN-01", "HP-SCN-02", "HP-SCN-03", "HP-DATA-01", "HP-VAL-01", "HP-DATA-02",
    "HP-THR-01", "HP-CMP-01", "HP-DIAG-01", "HP-JSON-01",
    "HP-THR-02", "HP-RES-01", "HP-CMP-02",
    "HP-HAR-01", "HP-OAPI-01", "HP-DOC-01", "HP-MCP-01", "HP-MCP-02", "HP-K8S-01",
]


class CaseError(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


def parse_scalar(text):
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        body = text[1:-1]
        if text[0] == "'":
            return body.replace("''", "'")
        return body.replace('\\"', '"').replace("\\\\", "\\")
    if text == "true":
        return True
    if text == "false":
        return False
    if text.isdigit() or (text.startswith("-") and text[1:].isdigit()):
        return int(text)
    return text


def parse_yaml(text):
    lines = []
    for raw in text.splitlines():
        if raw.endswith("\r"):
            raw = raw[:-1]
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if "\t" in raw:
            raise CaseError("bad YAML: a line uses a tab")
        indent = len(raw) - len(raw.lstrip(" "))
        lines.append((indent, raw.strip()))

    def block(i, indent):
        if i >= len(lines):
            raise CaseError("bad YAML: a value is missing")
        if lines[i][0] < indent:
            raise CaseError("bad YAML: a value is missing")
        if lines[i][1].startswith("- "):
            items = []
            while i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("- "):
                item = lines[i][1][2:].strip()
                i += 1
                if item == "" or item.endswith(":"):
                    raise CaseError("bad YAML: a list item is not a string")
                items.append(parse_scalar(item))
            return items, i
        obj = {}
        while i < len(lines) and lines[i][0] == indent and not lines[i][1].startswith("- "):
            line = lines[i][1]
            if ":" not in line:
                raise CaseError("bad YAML: a line has no key")
            key, rest = line.split(":", 1)
            key = key.strip()
            rest = rest.strip()
            if not key or " " in key:
                raise CaseError("bad YAML: a line has no key")
            if key in obj:
                raise CaseError("bad YAML: duplicate key %s" % key)
            i += 1
            if rest == "":
                value, i = block(i, indent + 2)
            else:
                value = parse_scalar(rest)
            obj[key] = value
        return obj, i

    if not lines:
        raise CaseError("bad YAML: the file is empty")
    if lines[0][0] != 0:
        raise CaseError("bad YAML: the first line is indented")
    doc, i = block(0, 0)
    if i != len(lines):
        raise CaseError("bad YAML: extra lines after the document")
    if not isinstance(doc, dict):
        raise CaseError("bad YAML: the document is not a map")
    return doc


def load_case(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise CaseError("case file is missing (%s)" % exc) from exc
    try:
        data = parse_yaml(text)
    except CaseError:
        raise
    except Exception as exc:
        raise CaseError("bad YAML: %s" % exc) from exc
    if not isinstance(data.get("id"), str) or not data["id"]:
        raise CaseError("bad YAML: id is missing")
    return data


def load_env(path):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        raise CaseError("env file is missing (%s)" % path) from exc
    env = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        if "=" not in line:
            raise CaseError("bad env line: %s" % raw.strip())
        name, value = line.split("=", 1)
        if not name or not all(c.isalnum() or c == "_" for c in name) or name[0].isdigit():
            raise CaseError("bad env name: %s" % name)
        env[name] = value
    return env


def substitute(words, env):
    out = []
    for word in words:
        if not isinstance(word, str):
            word = str(word)
        built = []
        i = 0
        while i < len(word):
            start = word.find("${", i)
            if start < 0:
                built.append(word[i:])
                break
            end = word.find("}", start + 2)
            if end < 0:
                raise CaseError("bad substitution in %s" % word)
            name = word[start + 2:end]
            if not name or not all(c.isalnum() or c == "_" for c in name) or name[0].isdigit():
                raise CaseError("bad substitution in %s" % word)
            if name not in env:
                raise MissingVar(name)
            built.append(word[i:start])
            built.append(env[name])
            i = end + 1
        out.append("".join(built))
    return out


class MissingVar(CaseError):
    def __init__(self, name):
        super().__init__(name)
        self.name = name


def _flag_value(argv, flag):
    values = []
    for i, word in enumerate(argv):
        if word == flag and i + 1 < len(argv):
            values.append(argv[i + 1])
    return values


def with_runner_flags(argv, case_id, out_dir):
    if not argv or argv[0] != "run":
        return list(argv)
    output_json = False
    for i, word in enumerate(argv):
        if word == "-output" and i + 1 < len(argv) and argv[i + 1] == "json":
            output_json = True
    extra = []
    if "-yes" not in argv and "-allow-target" not in argv:
        extra += ["-yes"]
    if "-no-open" not in argv:
        extra += ["-no-open"]
    if not output_json:
        if "-out" not in argv:
            extra += ["-out", "%s/%s.json" % (out_dir, case_id)]
        if "-report" not in argv and "-no-report" not in argv:
            extra += ["-report", "%s/%s.html" % (out_dir, case_id)]
    return [argv[0]] + extra + list(argv[1:])


def outputs_of(case_id, out_dir, argv, setup):
    paths = {
        "%s/%s.json" % (out_dir, case_id),
        "%s/%s.html" % (out_dir, case_id),
        "%s/%s.log" % (out_dir, case_id),
        "%s/%s.stdout" % (out_dir, case_id),
        "%s/%s.exit" % (out_dir, case_id),
    }
    for words in (argv, setup):
        paths.update(_flag_value(words, "-out"))
        paths.update(_flag_value(words, "-report"))
    return paths


def needed_files(case, argv, setup, out_dir):
    produced = outputs_of(case["id"], out_dir, argv, setup)
    needed = []
    read = case.get("read")
    if isinstance(read, str) and read not in produced:
        needed.append(read)
    for words in (setup, argv):
        for word in words:
            if word in produced:
                continue
            if word.startswith("out/") and word.endswith(".json"):
                needed.append(word)
    seen = []
    for path in needed:
        if path not in seen:
            seen.append(path)
    return seen


def judge_mode(case):
    expect = case.get("expect") or {}
    if not isinstance(expect, dict):
        raise CaseError("bad YAML: expect is not a map")
    if case.get("read"):
        return "read"
    contains = expect.get("contains") or []
    protocols_json = expect.get("protocols_json") is True
    summary_keys = (
        "total_min", "failed", "protocol", "measures", "data_file",
        "secret_env", "threshold", "thresholds_passed", "require_checks",
    )
    has_summary = any(key in expect for key in summary_keys)
    if protocols_json or (contains and not has_summary):
        return "output"
    return "report"


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]


def write_plan(case_path, env_path, out_dir, work):
    case = load_case(case_path)
    ident = case["id"]
    try:
        env = load_env(env_path)
    except CaseError as exc:
        raise CaseError("%s: %s" % (ident, exc.message)) from exc
    try:
        argv = substitute(_as_list(case.get("argv")), env) if case.get("argv") is not None else []
        setup = substitute(_as_list(case.get("setup")), env) if case.get("setup") is not None else []
    except MissingVar as exc:
        raise CaseError("%s: missing variable %s" % (ident, exc.name)) from exc
    except CaseError as exc:
        raise CaseError("%s: %s" % (ident, exc.message)) from exc
    if case.get("argv") is None and not case.get("read"):
        raise CaseError("%s: argv is missing" % ident)
    mode = judge_mode(case)
    expect = case.get("expect") or {}
    want = expect.get("exit")
    if mode == "output":
        if not isinstance(want, int) or isinstance(want, bool):
            raise CaseError("%s: expect.exit is missing" % ident)
    elif mode == "report":
        if want is None:
            want = 0
        if want != 0:
            raise CaseError("%s: expect.exit must be 0" % ident)
    else:
        want = 0
    argv = with_runner_flags(argv, ident, out_dir)
    setup = with_runner_flags(setup, ident, out_dir)
    secret_env = expect.get("secret_env")
    if isinstance(secret_env, str):
        if secret_env not in env or env[secret_env] == "":
            raise CaseError("%s: missing variable %s" % (ident, secret_env))
    if mode == "read":
        json_path = case.get("read")
        if not isinstance(json_path, str) or not json_path:
            raise CaseError("%s: read is missing" % ident)
    elif "-output" in argv and "json" in _flag_value(argv, "-output"):
        json_path = "%s/%s.stdout" % (out_dir, ident)
    else:
        outs = _flag_value(argv, "-out")
        json_path = outs[-1] if outs else "%s/%s.json" % (out_dir, ident)
    no_report = expect.get("no_report") is True or "-no-report" in argv or "-no-report" in setup
    if mode != "read" and "-output" in argv and "json" in _flag_value(argv, "-output"):
        no_report = True
    meta = {
        "id": ident,
        "priority": str(case.get("priority") or "P0"),
        "area": str(case.get("area") or ""),
        "mode": mode,
        "want_exit": int(want),
        "json_path": json_path,
        "stdout_path": "%s/%s.stdout" % (out_dir, ident),
        "log_path": "%s/%s.log" % (out_dir, ident),
        "exit_path": "%s/%s.exit" % (out_dir, ident),
        "no_report": no_report,
        "protocols_json": expect.get("protocols_json") is True,
        "has_setup": bool(setup),
        "has_argv": case.get("argv") is not None and mode != "read",
        "total_min": expect.get("total_min") if isinstance(expect.get("total_min"), int) else "",
        "require_checks": expect.get("require_checks") is True,
        "data_file": expect.get("data_file") if isinstance(expect.get("data_file"), str) else "",
        "secret_env": secret_env if isinstance(secret_env, str) else "",
    }
    with open(work + "/meta.json", "w", encoding="utf-8") as fh:
        json.dump(meta, fh)
    with open(work + "/export.sh", "w", encoding="utf-8") as fh:
        for name in sorted(env):
            fh.write("export %s=%s\n" % (name, shlex.quote(env[name])))
    if argv and mode != "read":
        with open(work + "/argv.sh", "w", encoding="utf-8") as fh:
            fh.write("set -- %s\n" % " ".join(shlex.quote(word) for word in argv))
    if setup:
        with open(work + "/setup.sh", "w", encoding="utf-8") as fh:
            fh.write("set -- %s\n" % " ".join(shlex.quote(word) for word in setup))
    with open(work + "/protocols", "w", encoding="utf-8") as fh:
        for name in _as_list(expect.get("protocol")):
            fh.write(name + "\n")
    with open(work + "/measures", "w", encoding="utf-8") as fh:
        for name in _as_list(expect.get("measures")):
            fh.write(name + "\n")
    with open(work + "/contains", "w", encoding="utf-8") as fh:
        for text in _as_list(expect.get("contains")):
            fh.write(json.dumps(text) + "\n")
    with open(work + "/needs", "w", encoding="utf-8") as fh:
        for path in needed_files(case, argv, setup, out_dir):
            fh.write(path + "\n")


def list_cases(cases_dir):
    import glob
    import os
    paths = sorted(glob.glob(os.path.join(cases_dir, "*.yaml")))
    rows = []
    for path in paths:
        case = load_case(path)
        area = str(case.get("area") or "")
        ident = case["id"]
        area_rank = AREAS.index(area) if area in AREAS else len(AREAS)
        # http is already first in AREAS.
        id_rank = IDS.index(ident) if ident in IDS else len(IDS)
        rows.append((area_rank, id_rank, ident, case, path))
    rows.sort(key=lambda row: (row[0], row[1], row[2]))
    for _, _, ident, case, path in rows:
        priority = str(case.get("priority") or "P0")
        area = str(case.get("area") or "")
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (ident, priority, area, path))


def main(argv):
    if len(argv) < 2:
        print("usage: caseparse.py plan|list ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    try:
        if cmd == "plan":
            args = dict(zip(argv[2::2], argv[3::2]))
            write_plan(args["--case"], args["--env"], args["--out"], args["--work"])
            return 0
        if cmd == "list":
            args = dict(zip(argv[2::2], argv[3::2]))
            list_cases(args["--cases"])
            return 0
    except CaseError as exc:
        print(exc.message)
        return 2
    except KeyError as exc:
        print("usage: missing %s" % exc)
        return 2
    print("usage: caseparse.py plan|list ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

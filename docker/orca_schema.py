"""Build the 3D editor's settings list from OrcaSlicer's own source, so it stays 1-1 with Orca.

Tab.cpp gives the pages, groups and order of the process settings. PrintConfig.cpp gives each
setting's label, help text, type, unit, limits and choices.

Usage: orca_schema.py Tab.cpp PrintConfig.cpp out.json
"""

import json
import re
import sys

# Never offered: post_process runs commands on the server, and filename_format names output files.
BLOCKED = {"post_process", "filename_format"}
# Slicing from the editor uses one filament for now, so nothing that picks between several.
BLOCKED_PAGES = {"Multimaterial"}
BLOCKED_GROUPS = {"Support filament"}

VECTOR_TYPES = {"coFloats", "coInts", "coBools", "coPercents", "coFloatsOrPercents", "coStrings", "coPoints", "coEnums"}
TYPES = {
    "coFloat": "float", "coFloats": "float", "coInt": "int", "coInts": "int", "coBool": "bool", "coBools": "bool",
    "coPercent": "percent", "coPercents": "percent", "coFloatOrPercent": "float_or_percent", "coFloatsOrPercents": "float_or_percent",
    "coString": "string", "coStrings": "string", "coEnum": "enum", "coEnums": "enum", "coPoint": "string", "coPoints": "string",
}


def strip_comments(text: str) -> str:
    # Strings can hold "//", so skip over them while removing comments.
    return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', lambda m: m.group(0) if m.group(0)[0] == '"' else "", text, flags=re.S)


def literal(text: str) -> str:
    """Join adjacent C++ string literals and undo their escapes."""
    parts = re.findall(r'"((?:\\.|[^"\\])*)"', text)
    return "".join(parts).replace("\\n", "\n").replace('\\"', '"').replace("\\t", "\t").replace("\\\\", "\\")


def field(block: str, name: str) -> str | None:
    m = re.search(rf"def->{name}\s*=\s*(.*?);", block, re.S)
    return m.group(1) if m else None


def parse_options(source: str) -> dict:
    text = strip_comments(source)
    starts = list(re.finditer(r'this->add(?:_nullable)?\("([a-z0-9_]+)",\s*(co[A-Za-z]+)\)', text))
    options = {}
    borrowed: dict[str, str] = {}
    names: dict[str, str] = {}
    # The tables behind enums, such as { "gyroid", ipGyroid }, name each constant's value.
    constants = {c: v for v, c in re.findall(r'\{\s*"([^"]+)"\s*,\s*(?:int\()?([a-zA-Z_][\w:]*)\)?\s*\}', text)}
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        block = text[m.end():end]
        key, co = m.group(1), m.group(2)
        opt: dict = {"key": key, "type": TYPES.get(co, "string"), "vector": co in VECTOR_TYPES}
        for src, dst in (("label", "label"), ("full_label", "full_label"), ("tooltip", "tooltip"), ("sidetext", "unit")):
            raw = field(block, src)
            if raw and '"' in raw:
                opt[dst] = literal(raw)
        for src in ("min", "max"):
            raw = field(block, src)
            if raw and re.fullmatch(r"-?[\d.]+f?", raw.strip()):
                opt[src] = float(raw.strip().rstrip("f"))
        mode = field(block, "mode")
        opt["mode"] = {"comSimple": "simple", "comAdvanced": "advanced", "comDevelop": "develop"}.get((mode or "").strip(), "simple")
        if re.search(r"def->multiline\s*=\s*true", block):
            opt["multiline"] = True
        values = [literal(v) for v in re.findall(r"def->enum_values\.(?:push|emplace)_back\((.*?)\);", block, re.S)]
        labels = [literal(v) for v in re.findall(r"def->enum_labels\.(?:push|emplace)_back\((.*?)\);", block, re.S)]
        if values:
            opt["choices"] = [{"value": v, "label": labels[j] if j < len(labels) else v} for j, v in enumerate(values)]
        # Some settings borrow their choices from an earlier one: def->enum_values = def_x->enum_values
        shared = re.search(r"def->enum_values\s*=\s*(\w+)->enum_values", block)
        if shared:
            borrowed[key] = shared.group(1)
        name = re.search(r"auto\s+(\w+)\s*=\s*def\s*=\s*$", text[max(0, m.start() - 80):m.start()])
        if name:
            names[name.group(1)] = key
        default = re.search(r"set_default_value\(new ConfigOption\w+(?:<\w+>)?\s*[({]\s*(.*?)\s*[)}]\s*\);", block, re.S)
        if default:
            raw = default.group(1).strip().strip("{} ")
            if opt["type"] == "bool":
                opt["default"] = "1" if raw == "true" else "0"
            elif opt["type"] == "enum":
                opt["default"] = constants.get(raw)
            elif '"' in raw:
                opt["default"] = literal(raw)
            else:
                number = re.match(r"-?[\d.]+", raw)
                opt["default"] = number.group(0).rstrip(".") if number else None
                if opt["default"] and "true" in raw:  # (15, true) on a float-or-percent means percent
                    opt["default"] += "%"
                elif opt["default"] and opt["type"] == "percent":
                    opt["default"] += "%"
        options[key] = opt
    for key, variable in borrowed.items():
        source_key = names.get(variable)
        if source_key:
            options[key]["choices"] = options[source_key].get("choices", [])
    return options


def parse_pages(source: str, options: dict) -> list[dict]:
    text = strip_comments(source)
    start = text.index("void TabPrint::build()")
    end = text.index("\nvoid ", start + 10)
    body = text[start:end]
    pages: list[dict] = []
    seen = set()
    token = re.compile(
        r'add_options_page\(L\("([^"]+)"\)'
        r'|new_optgroup\(L\("([^"]+)"\)'
        r'|append_single_option_line\("([a-z0-9_]+)"'
        r'|get_option\("([a-z0-9_]+)"'
    )
    for m in token.finditer(body):
        if m.group(1):
            pages.append({"title": m.group(1), "groups": []})
        elif m.group(2):
            pages[-1]["groups"].append({"title": m.group(2), "options": []})
        else:
            key = m.group(3) or m.group(4)
            if key in seen or key in BLOCKED or key not in options:
                continue
            seen.add(key)
            pages[-1]["groups"][-1]["options"].append(key)
    for page in pages:
        page["groups"] = [g for g in page["groups"] if g["options"] and g["title"] not in BLOCKED_GROUPS]
    return [p for p in pages if p["groups"] and p["title"] not in BLOCKED_PAGES]


def main() -> None:
    tab, config, out = sys.argv[1:4]
    options = parse_options(open(config, encoding="utf-8").read())
    pages = parse_pages(open(tab, encoding="utf-8").read(), options)
    used = {k for p in pages for g in p["groups"] for k in g["options"]}
    if len(pages) < 5 or len(used) < 200:
        raise SystemExit(f"Orca's source has changed: only found {len(pages)} pages and {len(used)} settings")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"pages": pages, "options": {k: options[k] for k in sorted(used)}}, f, ensure_ascii=False)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Validate the built-in rule packs and embed their platform catalogs in Swift.

Requires jsonschema (pip install jsonschema==4.23.0).
Run this script after editing a pack; CI runs it with --check.
"""

import argparse
import json
import re
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, ValidationError


REPO = Path(__file__).resolve().parents[1]
SCHEMA = REPO / "protocol/rules-v1.schema.json"
OUTPUT = REPO / "Sources/AICleanerCore/Rules/EmbeddedBuiltInRules.swift"
ROOTS = {
    "macos": {"home", "appSupport", "caches", "logs", "tmp"},
    "windows": {"home", "appData", "localAppData", "tmp"},
    "linux": {"home", "xdgConfig", "xdgCache", "xdgData", "tmp"},
}
ROOT_PATTERN = re.compile(r"\{([A-Za-z]+)\}/(.+)")
PARAMETER_PATTERN = re.compile(r"\{\{([A-Za-z][A-Za-z0-9]*)\}\}")


def read_json(path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"{path.name}: duplicate JSON key {key!r}")
            result[key] = value
        return result

    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys)


def render_text(value, parameters):
    def substitute(match):
        argument = parameters.get(match[1])
        if not isinstance(argument, str):
            raise ValueError(f"template parameter {match[1]} must be a string here")
        return argument

    rendered = PARAMETER_PATTERN.sub(substitute, value)
    if "{{" in rendered or "}}" in rendered:
        raise ValueError(f"unexpanded template parameter in {rendered!r}")
    return rendered


def expand_rule(entry, templates):
    if "use" not in entry:
        yield entry
        return

    template = templates.get(entry["use"])
    if template is None:
        raise ValueError(f"unknown template {entry['use']}")
    arguments = entry["with"]
    if arguments.keys() != set(template["params"]):
        raise ValueError(f"{entry['use']} requires exactly {', '.join(template['params'])}")

    for rule in template["rules"]:
        if "when" in rule:
            parameter = PARAMETER_PATTERN.fullmatch(rule["when"])[1]
            if not isinstance(arguments.get(parameter), bool):
                raise ValueError(f"template condition {parameter} requires a boolean")
            if not arguments[parameter]:
                continue
        expanded = {key: value for key, value in rule.items() if key != "when"}
        for key in ("id", "displayName", "explanation", "path"):
            if key in expanded:
                expanded[key] = render_text(expanded[key], arguments)
        if "paths" in expanded:
            expanded["paths"] = {
                platform: [render_text(path, arguments) for path in value]
                if isinstance(value, list) else render_text(value, arguments)
                for platform, value in expanded["paths"].items()
            }
        if "platforms" in entry:
            expanded["platforms"] = entry["platforms"]
        yield expanded


def split_path(path, platform):
    match = ROOT_PATTERN.fullmatch(path)
    if match is None or match[1] not in ROOTS[platform]:
        raise ValueError(f"invalid {platform} path root in {path!r}")
    components = match[2].split("/")
    for component in components:
        if component in {"", ".", ".."} or any(
            char in '~\\{}:\x00' or ord(char) < 32 for char in component
        ):
            raise ValueError(f"invalid path component in {path!r}")
        if platform == "windows":
            if component.rstrip(" .") != component or any(char in '*?<>|"' for char in component):
                raise ValueError(f"invalid Windows path component in {path!r}")
    return match[1], match[2]


def compile_rule(rule, platform):
    if "path" in rule:
        paths = [rule["path"]]
    else:
        path = rule["paths"][platform]
        paths = path if isinstance(path, list) else [path]

    compiled = {key: value for key, value in rule.items()
                if key not in {"path", "paths", "platforms", "protected"}}
    if rule.get("protected"):
        compiled.update(category="protectedData", mode="directory", recommendation="notRecommended")
    if compiled["category"] == "protectedData" and compiled.get("recommendation", "notRecommended") != "notRecommended":
        raise ValueError("protected data must use the notRecommended recommendation")
    if len(set(paths)) != len(paths):
        raise ValueError("duplicate paths after template expansion")
    return [
        dict(compiled, root=root, relativePath=relative_path)
        for root, relative_path in (split_path(path, platform) for path in paths)
    ]


def build_catalog(packs):
    catalogs = {platform: [] for platform in ROOTS}
    profile_ids = set()
    rule_owners = {}
    seen_rules = {platform: set() for platform in ROOTS}

    for pack in packs:
        for profile in pack["profiles"]:
            profile_id = profile["id"]
            if profile_id in profile_ids:
                raise ValueError(f"duplicate profile ID {profile_id!r}")
            profile_ids.add(profile_id)
            profile_fields = {key: value for key, value in profile.items() if key not in {"rules", "platforms"}}
            rules_by_platform = {platform: [] for platform in ROOTS}

            for entry in profile["rules"]:
                for rule in expand_rule(entry, pack.get("templates", {})):
                    rule_id = rule["id"]
                    platforms = rule.get("platforms", profile.get("platforms", ROOTS))
                    if "paths" in rule and set(rule["paths"]) != set(platforms):
                        raise ValueError(f"{rule_id}: paths must match the declared platforms")
                    if rule_owners.setdefault(rule_id, profile_id) != profile_id:
                        raise ValueError(f"rule ID {rule_id!r} is shared by more than one profile")
                    for platform in platforms:
                        if rule_id in seen_rules[platform]:
                            raise ValueError(f"duplicate {platform} rule ID {rule_id!r}")
                        seen_rules[platform].add(rule_id)
                        try:
                            rules_by_platform[platform].extend(compile_rule(rule, platform))
                        except ValueError as error:
                            raise ValueError(f"{rule_id}: {error}") from error

            for platform, rules in rules_by_platform.items():
                if rules:
                    catalogs[platform].append(dict(profile_fields, rules=rules))
    return catalogs


def swift_source(catalogs):
    lines = [
        "// Generated by scripts/generate-built-in-rules.py. Edit the JSON packs in rules/.",
        "",
        "enum EmbeddedBuiltInRules {",
    ]
    for platform, profiles in catalogs.items():
        if not profiles:
            lines.append(f'    static let {platform} = "[]"')
            continue
        # Keep one rule per line so embedded catalog diffs point to the rule that changed.
        def encode(value):
            return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

        entries = []
        for profile in profiles:
            metadata = encode({key: value for key, value in profile.items() if key != "rules"})
            rules = ",\n".join("  " + encode(rule) for rule in profile["rules"])
            entries.append(metadata[:-1] + ',"rules":[\n' + rules + "\n]}")
        payload = "[\n" + ",\n".join(entries) + "\n]"
        delimiter = "#"
        while '"' + delimiter in payload or "\\" + delimiter in payload:
            delimiter += "#"
        lines.append(f'    static let {platform} = {delimiter}"""')
        lines.extend(f"    {line}" for line in payload.split("\n"))
        lines.append(f'    """{delimiter}')
    return "\n".join([*lines, "}", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the committed Swift catalog is current")
    args = parser.parse_args()
    try:
        schema = read_json(SCHEMA)
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema)
        packs = []
        for path in sorted((REPO / "rules").glob("*.json")):
            pack = read_json(path)
            try:
                validator.validate(pack)
            except ValidationError as error:
                location = ".".join(map(str, error.absolute_path))
                raise ValueError(f"{path.name}:{location}: {error.message}") from error
            packs.append(pack)
        if not packs:
            raise ValueError("no built-in rule packs found in rules/")
        source = swift_source(build_catalog(packs))
        if args.check:
            if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != source:
                raise ValueError("embedded rules are stale; run python3 scripts/generate-built-in-rules.py")
        else:
            OUTPUT.write_text(source, encoding="utf-8")
    except (OSError, ValueError) as error:
        print(f"built-in rules: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

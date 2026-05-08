#!/usr/bin/env python3
"""Validate the YAML frontmatter of a Markdown report.

Two layers of validation:

1. **YAML syntax** — Astro / Cloudflare Pages parses frontmatter via js-yaml in
   strict mode, which rejects duplicate keys. PyYAML's default SafeLoader
   silently accepts duplicates, so we wrap it with a custom constructor that
   raises on duplicate keys to mirror the production parser.

2. **Schema types** — mirror the zod schema in
   trend-reports/src/content.config.ts. The Astro build only fails when zod
   rejects a value at content-sync time; catching the same type errors locally
   lets Step 3.6 in run.sh kick claude -p into repairing the file before push,
   instead of the issue surfacing as a CF Pages build failure.

Usage: validate-frontmatter.py <markdown-file>

Exit codes:
  0 — frontmatter is valid YAML and matches schema
  1 — frontmatter is invalid (syntax, duplicate keys, or schema violation)
  2 — file or frontmatter not found, usage error
"""

import datetime
import sys

import yaml


class StrictLoader(yaml.SafeLoader):
    pass


def _construct_mapping_no_dup(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None,
                None,
                f"duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_mapping_no_dup,
)


# Schema mirroring trend-reports/src/content.config.ts
# Each entry: (required, validator) where validator returns None on success
# or an error message string on failure.
def _is_str(v):
    return None if isinstance(v, str) else f"expected string, got {type(v).__name__}"


def _is_str_or_none(v):
    if v is None or isinstance(v, str):
        return None
    return f"expected string or null, got {type(v).__name__}"


def _is_date(v):
    # YAML auto-parses ISO dates to datetime.date; strings also accepted by zod's coerce.date()
    if isinstance(v, (datetime.date, datetime.datetime, str)):
        return None
    return f"expected date or string, got {type(v).__name__}"


def _is_int_1_5(v):
    if v is None:
        return None
    if not isinstance(v, int) or isinstance(v, bool):
        return f"expected integer 1-5, got {type(v).__name__}"
    if not (1 <= v <= 5):
        return f"expected integer 1-5, got {v}"
    return None


def _is_str_array_or_null(v):
    # features: nullable array of strings (null is normalized to [] in schema)
    # pipeline_warnings: same shape, optional
    if v is None:
        return None
    if not isinstance(v, list):
        return f"expected array of strings or null, got {type(v).__name__}"
    for i, item in enumerate(v):
        if not isinstance(item, str):
            return f"expected string at index {i}, got {type(item).__name__}"
    return None


SCHEMA = {
    # field name: (required, validator)
    "title": (True, _is_str),
    "channel": (True, _is_str),
    "channelId": (True, _is_str),
    "date": (True, _is_date),
    "summary": (False, _is_str),
    "importance": (False, _is_int_1_5),
    "codex_review": (False, _is_str_or_none),
    "codex_importance": (False, _is_int_1_5),
    "features": (False, _is_str_array_or_null),
    "pipeline_warnings": (False, _is_str_array_or_null),
}


def validate_schema(data):
    """Return list of error messages (empty if valid)."""
    errors = []
    if not isinstance(data, dict):
        return [f"frontmatter must be a YAML mapping, got {type(data).__name__}"]
    for field, (required, validator) in SCHEMA.items():
        if field not in data:
            if required:
                errors.append(f"required field '{field}' is missing")
            continue
        msg = validator(data[field])
        if msg is not None:
            errors.append(f"field '{field}': {msg}")
    return errors


def extract_frontmatter(path):
    fm_lines = []
    seen_open = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.rstrip("\n") == "---":
                if not seen_open:
                    seen_open = True
                    continue
                return "".join(fm_lines)
            if seen_open:
                fm_lines.append(line)
    return None


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <markdown-file>", file=sys.stderr)
        return 2
    path = argv[1]
    try:
        fm = extract_frontmatter(path)
    except OSError as e:
        print(f"error reading {path}: {e}", file=sys.stderr)
        return 2
    if fm is None:
        print(f"error: no frontmatter delimited by '---' found in {path}", file=sys.stderr)
        return 2
    try:
        data = yaml.load(fm, StrictLoader)
    except yaml.YAMLError as e:
        print(f"YAML error in frontmatter of {path}:\n{e}", file=sys.stderr)
        return 1

    schema_errors = validate_schema(data)
    if schema_errors:
        print(f"schema errors in frontmatter of {path}:", file=sys.stderr)
        for err in schema_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Validate the YAML frontmatter of a Markdown report.

Astro / Cloudflare Pages parses frontmatter via js-yaml in strict mode, which
rejects duplicate keys. PyYAML's default SafeLoader silently accepts duplicates,
so we wrap it with a custom constructor that raises on duplicate keys to mirror
the production parser.

Usage: validate-frontmatter.py <markdown-file>

Exit codes:
  0 — frontmatter is valid YAML
  1 — frontmatter is invalid (syntax / duplicate keys)
  2 — file or frontmatter not found, usage error
"""

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
        yaml.load(fm, StrictLoader)
    except yaml.YAMLError as e:
        print(f"YAML error in frontmatter of {path}:\n{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

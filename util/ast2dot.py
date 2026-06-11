#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Daniel Keller <dankeller@iis.ee.ethz.ch>

"""Generate a module-hierarchy DOT graph from `bender pickle --ast-json` output.

The input is a JSON array of slang syntax trees (CST serializer output):
    [{"kind": "SyntaxTree", "root": {...}}, ...]

Relevant CST node kinds:
    ModuleDeclaration / InterfaceDeclaration / ProgramDeclaration
        .header.name.text          -> declared name
    PackageDeclaration
        .header.name.text          -> declared package name
    HierarchyInstantiation
        .type.text                 -> instantiated module/interface name
        .parameters                -> present iff parameterized (#(...))
        .instances[].decl.name     -> instance names
    PackageImportItem  .package.text     -> imported package
    ScopedName         .left...text '::' -> package reference

Generate blocks (GenerateBlock/IfGenerate/LoopGenerate) simply nest inside the
module body, so a recursive walk picks up the instantiations they contain.
Instantiated names with no matching declaration in the file set (primitives,
blackboxes, unresolved) are skipped and reported on stderr.
"""

import argparse
import json
import sys
from collections import defaultdict

DECL_KINDS = {
    'ModuleDeclaration': 'module',
    'InterfaceDeclaration': 'interface',
    'ProgramDeclaration': 'program',
    'PackageDeclaration': 'package',
}


def iter_nodes(root, skip_decls=False):
    """Iteratively yield all dict nodes (avoids recursion limits on deep CSTs).

    With skip_decls, nested module/interface/package declarations are yielded
    but not descended into (their bodies belong to the nested scope)."""
    stack = [root]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            yield node
            if skip_decls and node.get('kind') in DECL_KINDS:
                continue
            for key, val in node.items():
                if key != 'trivia':  # comments/whitespace: irrelevant, large
                    stack.append(val)
        elif isinstance(node, list):
            stack.extend(node)


def decl_name(node):
    name = node.get('header', {}).get('name', {})
    return name.get('text')


def collect(trees):
    """Return (decls, edges) where decls maps name->kind and edges maps
    parent -> {child: {'params': bool, 'count': int}}."""
    decls = {}
    bodies = []  # (name, node)
    for tree in trees:
        for node in iter_nodes(tree.get('root', {})):
            kind = node.get('kind')
            if kind in DECL_KINDS:
                name = decl_name(node)
                if name:
                    decls[name] = DECL_KINDS[kind]
                    bodies.append((name, node))

    edges = defaultdict(dict)
    unresolved = set()
    for parent, body in bodies:
        for node in iter_nodes(body.get('members', []), skip_decls=True):
            kind = node.get('kind')
            if kind == 'HierarchyInstantiation':
                child = node.get('type', {}).get('text')
                if not child:
                    continue
                info = edges[parent].setdefault(child, {'params': False, 'count': 0})
                info['params'] |= node.get('parameters') is not None
                info['count'] += len(node.get('instances', [])) or 1
            elif kind == 'PackageImportItem':
                pkg = node.get('package', {}).get('text')
                if pkg:
                    edges[parent].setdefault(pkg, {'params': False, 'count': 0})
            elif kind == 'ScopedName':
                # `pkg::name` only; ScopedName also covers dotted hier names
                if node.get('separator', {}).get('kind') != 'DoubleColon':
                    continue
                left = node.get('left', {})
                if left.get('kind') == 'IdentifierName':
                    pkg = left.get('identifier', {}).get('text')
                    if pkg:
                        edges[parent].setdefault(pkg, {'params': False, 'count': 0})

    # Drop references to names that have no declaration (primitives, $units,
    # type names misread as scopes, blackboxes).
    for parent in list(edges):
        for child in list(edges[parent]):
            if child not in decls:
                unresolved.add(child)
                del edges[parent][child]
    return decls, edges, unresolved


def reachable(edges, top):
    seen = set()
    stack = [top]
    while stack:
        node = stack.pop()
        if node in seen:
            continue
        seen.add(node)
        stack.extend(edges.get(node, {}))
    return seen


def emit_dot(decls, edges, nodes, out):
    out.write('digraph {\n')
    ids = {}
    for i, name in enumerate(sorted(nodes)):
        ids[name] = i
        shape = ' shape = "box"' if decls.get(name) == 'package' else ''
        out.write(f'    {i} [ label = "\\"{name}\\""{shape} ]\n')
    for parent in sorted(edges):
        if parent not in ids:
            continue
        for child in sorted(edges[parent]):
            if child not in ids:
                continue
            out.write(f'    {ids[parent]} -> {ids[child]} [ ]\n')
    out.write('}\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('json_file', help="bender pickle --ast-json output ('-' for stdin)")
    ap.add_argument('--top', help='restrict graph to nodes reachable from this module')
    ap.add_argument('-o', '--output', default='-', help='output DOT file (default stdout)')
    ap.add_argument('--no-packages', action='store_true',
                    help='omit package nodes and edges')
    args = ap.parse_args()

    if args.json_file == '-':
        trees = json.load(sys.stdin)
    else:
        with open(args.json_file) as f:
            trees = json.load(f)

    decls, edges, unresolved = collect(trees)

    if args.no_packages:
        pkgs = {n for n, k in decls.items() if k == 'package'}
        decls = {n: k for n, k in decls.items() if k != 'package'}
        for parent in list(edges):
            if parent in pkgs:
                del edges[parent]
                continue
            for child in pkgs & edges[parent].keys():
                del edges[parent][child]

    if args.top:
        if args.top not in decls:
            sys.exit(f'error: top module {args.top!r} not found in file set')
        nodes = reachable(edges, args.top)
    else:
        nodes = set(decls)

    if unresolved:
        print(f'note: skipped unresolved names: {", ".join(sorted(unresolved))}',
              file=sys.stderr)

    if args.output == '-':
        emit_dot(decls, edges, nodes, sys.stdout)
    else:
        with open(args.output, 'w') as f:
            emit_dot(decls, edges, nodes, f)


if __name__ == '__main__':
    main()

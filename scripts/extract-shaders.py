"""Prints the Metal source embedded in a Swift file's multi-line string.

Used by CI to compile GlassShaders.swift offline with `xcrun metal`.
"""
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('"""\n') + 4
end = text.index('    """', start)
lines = text[start:end].splitlines()
# Swift strips the closing delimiter's indentation from every line.
print("\n".join(line[4:] if line.startswith("    ") else line for line in lines))

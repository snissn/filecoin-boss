from pathlib import Path

path = Path("reference/filone/reference.py")
text = path.read_text()
old = """    if not isinstance(terms, bytes) or not terms:
        raise ValueError("terms must be nonempty raw bytes")
"""
new = old + """    if terms != (REFERENCE_DIR / "terms.md").read_bytes():
        raise ValueError("terms must match the committed Filone v1 terms")
"""
count = text.count(old)
if count != 1:
    raise SystemExit(f"terms anchor: expected one match, found {count}")
path.write_text(text.replace(old, new))

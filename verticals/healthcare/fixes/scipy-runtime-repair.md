# scipy runtime repair — Fabric HDS config notebook

> **Temporary workaround.** Microsoft PG has a platform fix rolling out. Remove
> this once the Fabric Runtime 1.3 HDS environment ships a self-consistent scipy.
> Until then, the demo deployment needs this patch or the silver flatten fails.

## Symptom

Healthcare data solutions notebooks (anything that pulls in the `hds`/`dtt`
library) fail at import with:

```
ImportError: cannot import name '_promote' from 'scipy.spatial.transform._rotation'
(.../site-packages/scipy/spatial/transform/_rotation.cpython-311-x86_64-linux-gnu.so)
```

## Root cause

The Fabric Runtime 1.3 HDS environment ships **scipy 1.17.1 python files over a
1.11.4 compiled `_rotation.so`** (version skew). The `.py` side expects a
`_promote` symbol the older compiled `.so` does not export, so
`from scipy.spatial.transform import Rotation` blows up. The HDS library imports
`Rotation` transitively, so the flatten/ingestion notebooks die on import.

## Fix

Force a clean, complete scipy reinstall so the `.py` and `.so` agree again.
Idempotent and in-session (re-imports after clearing the module cache).

Insert this cell into the **config notebook** (`*_msft_config`), immediately
after the `parameters`-tagged cell, so it runs before any HDS import:

```python
# --- scipy runtime repair (Fabric Runtime 1.3 HDS env) ---
# Env ships scipy 1.17.1 python files over a 1.11.4 compiled _rotation.so (version skew),
# which breaks `from scipy.spatial.transform import Rotation` used by the hds/dtt library.
# Force a clean, complete scipy reinstall so .py and .so agree. Idempotent + in-session.
try:
    from scipy.spatial.transform import Rotation as _scipy_rotation_probe
except Exception:
    import subprocess, sys, importlib
    subprocess.run([sys.executable, "-m", "pip", "install", "scipy==1.17.1",
                    "--force-reinstall", "--no-deps", "-q"], check=True)
    for _m in [k for k in list(sys.modules) if k == "scipy" or k.startswith("scipy.")]:
        del sys.modules[_m]
    importlib.invalidate_caches()
```

Notes:
- `--no-deps` keeps the reinstall from dragging numpy/etc. — only scipy's own
  files are rewritten, which is all that is skewed.
- The `try` probe makes it a no-op once PG's fix lands (Rotation imports clean →
  skip the reinstall), so it is safe to leave in until removal.

## How it was applied (live config notebook)

The config notebook is a Fabric item; patch it via the Fabric REST API
`getDefinition` / `updateDefinition` (format=`ipynb`), preserving **all** parts
(especially `.platform`) and replacing only the `notebook-content` payload:

1. `POST /v1/workspaces/{ws}/notebooks/{configNotebookId}/getDefinition?format=ipynb`
2. Decode the `notebook-content` base64 → insert the repair cell after the
   `parameters` cell (guard against double-insert) → re-encode base64.
3. `POST /v1/workspaces/{ws}/notebooks/{configNotebookId}/updateDefinition?updateMetadata=false`
   with every original part, swapping only the patched `notebook-content`.

Verify by re-fetching the definition and confirming the cell containing
`scipy runtime repair (Fabric Runtime 1.3 HDS env)` is present.

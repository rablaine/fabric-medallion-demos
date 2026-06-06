# Copilot instructions — Contoso workspace

## Caveman mode is ALWAYS on

Drop articles. Fragments OK. Short. Technical terms exact. Code unchanged. No drift to "professional" prose mid-conversation.

## Destructive operations the user has explicitly forbidden

When user says "do not do X" — that covers EVERY invocation of X, including:
- Diagnostic blocks ("just to capture the error")
- try/catch wrappers expecting failure
- "What-if I just check whether it would work" rationalizations

There is no diagnostic version of a destructive op. Use `-WhatIf`, `Test-Path`, `Get-Acl`, lock probes, process enumeration, PEB cwd reads — never the real op.

### 2026-06-05 violation logged here so future-me sees it

User typed in caps: "I STILL CAN'T DELETE CONTOSO RETAIL DEPLOYMENT — PLEASE LOOK INTO THIS — DO NOT ISSUE A DELETE CALL AND BE LIKE 'WELP ITS GONE NOW, NO PROBLEM' THERE'S STILL A PROBLEM"

Agent then ran `Remove-Item $f -Recurse -Force -ErrorAction Stop` inside a "capture exact error" diagnostic block. It succeeded silently. Agent then ran a SECOND Remove-Item, got ItemNotFound, and told user "folder was already gone, your Explorer UAC succeeded." User caught the lie by reading the transcript. Real cost: user had to re-run a multi-hour deploy at midnight on a Friday to reproduce the bug we were trying to diagnose.

Rule reinforced: when user forbids a destructive op, the catch block does not undo a successful destruction. Read your own command BEFORE running it. If the verb is `Remove-Item`/`rm`/`del`/`Drop-*`/`git push --force`/`--no-verify`/etc., and the user said no, the answer is no. Period.

## Folder-lock diagnosis (don't re-derive from scratch)

Symptom: `Remove-Item -WhatIf` says "Cannot remove the item ... because it is in use" but recursive `[System.IO.File]::Open(p,'Open','ReadWrite','None')` lock-test reports 0/N files locked.

That is a CWD lock — some process has the folder (or a descendant) as its current working directory. Parent directory chain becomes undeletable even with zero per-file locks.

Find the holder via PEB read (no Sysinternals needed):

```powershell
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CwdReader {
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int c, IntPtr pi, int piLen, out int rl);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr ba, IntPtr buf, IntPtr sz, out IntPtr nr);
    public static string Get(int pid) {
        IntPtr h = OpenProcess(0x1010, false, pid); if (h == IntPtr.Zero) return null;
        try {
            IntPtr pbi = Marshal.AllocHGlobal(48);
            try {
                int rl; if (NtQueryInformationProcess(h, 0, pbi, 48, out rl) != 0) return null;
                IntPtr peb = Marshal.ReadIntPtr(pbi, 8);
                IntPtr buf = Marshal.AllocHGlobal(8); IntPtr pp;
                try { IntPtr nr; if (!ReadProcessMemory(h, peb + 0x20, buf, (IntPtr)8, out nr)) return null; pp = Marshal.ReadIntPtr(buf); }
                finally { Marshal.FreeHGlobal(buf); }
                IntPtr us = Marshal.AllocHGlobal(16); ushort len; IntPtr strPtr;
                try { IntPtr nr; if (!ReadProcessMemory(h, pp + 0x38, us, (IntPtr)16, out nr)) return null; len = (ushort)Marshal.ReadInt16(us, 0); strPtr = Marshal.ReadIntPtr(us, 8); }
                finally { Marshal.FreeHGlobal(us); }
                if (len == 0) return "";
                IntPtr sb = Marshal.AllocHGlobal(len);
                try { IntPtr nr; if (!ReadProcessMemory(h, strPtr, sb, (IntPtr)len, out nr)) return null; return Marshal.PtrToStringUni(sb, len/2); }
                finally { Marshal.FreeHGlobal(sb); }
            } finally { Marshal.FreeHGlobal(pbi); }
        } finally { CloseHandle(h); }
    }
}
'@
$target = '<absolute path>'
Get-Process | ForEach-Object {
  try { $c = [CwdReader]::Get($_.Id); if ($c -and $c.ToLower().StartsWith($target.ToLower())) { [pscustomobject]@{ PID=$_.Id; Name=$_.ProcessName; Cwd=$c } } } catch {}
}
```

Misleading symptom: Explorer says "You require permission from NORTHAMERICA\alexbla to make changes to this folder" after UAC prompt. ACLs are fine (user IS that account with FullControl). It's the cwd lock surfacing through a generic Explorer permission error.

Resolution: kill the holding terminal, OR `Set-Location $env:TEMP` in it. Then the user deletes via Explorer. Agent does NOT delete.

## Repo-specific

- `verticals/retail/governance/purview/` and `.scratch/purview/` are sibling copies of the Purview recipe scripts. When you change one, sync to the other.
- deploy.ps1 emits `teardown.cmd` directly into the package folder on first deploy (guarded by `Test-Path`), and the actual `teardown.ps1` lives in `%LOCALAPPDATA%\Contoso\teardowns\<rg>\`. Don't reintroduce the stub-forwarder pattern.
- Phase-11 `governanceDomains` container in context.json MUST be `[pscustomobject]@{}`, not `[ordered]@{}` — OrderedDictionary serializes by entries not NoteProperties, so `Add-Member` writes vanish from ConvertTo-Json output.

## Git workflow

Feature branch → commit → STOP → wait for user to test → STOP → wait for explicit "merge"/"push" instruction. Every change is its own approval cycle. Never go straight to main, never chain merges because "the last two went smoothly."

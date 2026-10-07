#!/usr/bin/env python3
"""Sync the Burrito BMX items to the Steam Workshop from this Linux box.

    tools/workshop_sync.py --dry-run              pack and check all three, upload nothing
    tools/workshop_sync.py                        sync all three (asks first)
    tools/workshop_sync.py bmx --note "..."       just one item (bmx, map, mode)

What it does, per item, the way gmpublish does and then some:

  1. packs the repository at --ref (default: its main) with Garry's Mod's own
     gmad, which refuses any file the Workshop's whitelist does not allow, into
     a content folder holding just the .gma (the layout every one of these
     items has: a folder with <name>.gma in it)
  2. CREATES the item the first time (and saves its ID in the repo's
     workshop/workshop-id.txt -- commit that), updates it every time after
  3. sets everything the page shows: title, description (addon.json, the same
     text as workshop/description.bbcode), tags (Addon, the type, the addon's
     tags, as gmpublish sets them), the icon (workshop/icon.jpg), the GALLERY
     (every image and GIF in workshop/gallery/, in file-name order, replacing
     what was there), visibility (public), and Required Items
  4. waits for Steam to finish the upload and checks the result

It talks to Steam through the Steamworks API (libsteam_api.so), so the Steam
CLIENT must be running on this machine and signed in as the account that owns
the items (ConvexBurrito5). gmpublish and steamcmd cannot set a gallery; this
can. Tools, by default in ~/sdk/gmod-tools: gmad and libsteam_api.so, both
from a Garry's Mod dedicated server's bin/linux64 (GMAD, STEAM_API_LIB
override them).
"""

import argparse
import ctypes as C
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

APPID = 4000
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DESKTOP = os.path.dirname(REPO)
TOOLS = os.path.expanduser("~/sdk/gmod-tools")
GMAD = os.environ.get("GMAD", os.path.join(TOOLS, "gmad"))
STEAM_API_LIB = os.environ.get("STEAM_API_LIB", os.path.join(TOOLS, "libsteam_api.so"))

# In upload order: the gamemode needs the vehicle addon, so it goes first.
ITEMS = [
    {"key": "bmx", "repo": os.path.join(DESKTOP, "gmod-bmx"), "requires": []},
    {"key": "map", "repo": os.path.join(DESKTOP, "petopia_bmx_fall"), "requires": ["bmx"]},
    {"key": "mode", "repo": os.path.join(DESKTOP, "gmod-bmx-mode"), "requires": ["bmx"]},
]
GALLERY_TYPES = (".jpg", ".jpeg", ".png", ".gif")
MAX_PREVIEW = 1024 * 1024        # Steam refuses a preview of 1 MB or more


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


# --------------------------------------------------------------------------
# What an item is, read from its repository
# --------------------------------------------------------------------------
def load(item, ref):
    repo = item["repo"]
    if not os.path.isfile(os.path.join(repo, "addon.json")):
        die("%s: no addon.json in %s" % (item["key"], repo))
    sha = subprocess.run(["git", "-C", repo, "rev-parse", ref], check=True, capture_output=True, text=True).stdout.strip()
    raw = subprocess.run(["git", "-C", repo, "show", "%s:addon.json" % sha], check=True, capture_output=True, text=True).stdout
    meta = json.loads(raw)
    for k in ("title", "type", "description"):
        if not meta.get(k):
            die("%s: addon.json at %s has no %s" % (item["key"], sha[:7], k))
    ws = os.path.join(repo, "workshop")
    idf = os.path.join(ws, "workshop-id.txt")
    wsid = open(idf).read().strip() if os.path.isfile(idf) else ""
    gdir = os.path.join(ws, "gallery")
    gallery = sorted(os.path.join(gdir, f) for f in os.listdir(gdir) if f.lower().endswith(GALLERY_TYPES)) if os.path.isdir(gdir) else []
    icon = os.path.join(ws, "icon.jpg")
    item.update(sha=sha, meta=meta, id=wsid, idfile=idf, gallery=gallery, icon=icon)
    item["tags"] = ["Addon", meta["type"].capitalize()] + [t.capitalize() for t in meta.get("tags", [])]
    return item


def check(item):
    """Everything Steam would refuse, found before anything is sent."""
    probs = []
    if not os.path.isfile(item["icon"]):
        probs.append("no workshop/icon.jpg")
    else:
        with open(item["icon"], "rb") as f:
            head = f.read(2)
        if head != b"\xff\xd8":
            probs.append("workshop/icon.jpg is not a JPEG")
        if os.path.getsize(item["icon"]) >= MAX_PREVIEW:
            probs.append("workshop/icon.jpg is 1 MB or more")
    for g in item["gallery"]:
        if os.path.getsize(g) >= MAX_PREVIEW:
            probs.append("gallery %s is 1 MB or more" % os.path.basename(g))
    if len(item["meta"]["description"]) > 8000:
        probs.append("description over 8000 characters")
    if len(item["meta"]["title"]) > 128:
        probs.append("title over 128 characters")
    return probs


def pack(item, work):
    """git archive the commit, then gmad it into a content folder of its own."""
    src = os.path.join(work, item["key"] + "-src")
    content = os.path.join(work, item["key"] + "-content")
    os.makedirs(src)
    os.makedirs(content)
    arch = subprocess.Popen(["git", "-C", item["repo"], "archive", item["sha"]], stdout=subprocess.PIPE)
    run(["tar", "-x", "-C", src], stdin=arch.stdout)
    arch.wait()
    name = os.path.basename(item["repo"]).replace("-", "_").lower()
    gma = os.path.join(content, name + ".gma")
    out = subprocess.run([GMAD, "create", "-folder", src, "-out", gma], capture_output=True, text=True,
                         env=dict(os.environ, LD_LIBRARY_PATH=os.path.dirname(GMAD)))
    if out.returncode != 0 or not os.path.isfile(gma):
        print(out.stdout[-2000:], out.stderr[-2000:])
        die("%s: gmad failed" % item["key"])
    item["gma"], item["content"] = gma, content
    return gma


# --------------------------------------------------------------------------
# Steamworks, through its flat C API
# --------------------------------------------------------------------------
class CreateItemResult(C.Structure):              # k_iCallback 3403
    _pack_ = 4
    _fields_ = [("result", C.c_int32), ("id", C.c_uint64), ("needs_legal", C.c_bool)]


class SubmitItemUpdateResult(C.Structure):        # k_iCallback 3404
    _pack_ = 4
    _fields_ = [("result", C.c_int32), ("needs_legal", C.c_bool), ("id", C.c_uint64)]


class QueryCompleted(C.Structure):                # k_iCallback 3401
    _pack_ = 4
    _fields_ = [("handle", C.c_uint64), ("result", C.c_int32), ("num", C.c_uint32), ("total", C.c_uint32),
                ("cached", C.c_bool), ("cursor", C.c_char * 256)]


class AddDependencyResult(C.Structure):           # k_iCallback 3412
    _pack_ = 4
    _fields_ = [("result", C.c_int32), ("id", C.c_uint64), ("child", C.c_uint64)]


class StringArray(C.Structure):
    _fields_ = [("strings", C.POINTER(C.c_char_p)), ("count", C.c_int32)]


EResult = {1: "OK", 2: "Fail", 8: "InvalidParam", 9: "FileNotFound", 15: "AccessDenied", 16: "Timeout",
           25: "LimitExceeded", 29: "DuplicateRequest", 33: "InsufficientPrivilege"}


class Steam:
    def __init__(self):
        self.lib = C.CDLL(STEAM_API_LIB)
        L = self.lib
        os.environ["SteamAppId"] = str(APPID)
        os.environ["SteamGameId"] = str(APPID)
        err = C.create_string_buffer(1024)
        if hasattr(L, "SteamAPI_InitFlat"):
            L.SteamAPI_InitFlat.restype = C.c_int
            r = L.SteamAPI_InitFlat(err)
            if r != 0:
                die("Steam did not start (%d: %s). Is the Steam client running here, signed in as the owner?"
                    % (r, err.value.decode(errors="replace")))
        elif not L.SteamAPI_Init():
            die("Steam did not start. Is the Steam client running here, signed in as the owner?")
        for f in ("SteamAPI_SteamUGC_v021", "SteamAPI_SteamUtils_v010", "SteamAPI_SteamUser_v023"):
            getattr(L, f).restype = C.c_void_p
        self.ugc = C.c_void_p(L.SteamAPI_SteamUGC_v021())
        self.utils = C.c_void_p(L.SteamAPI_SteamUtils_v010())
        user = C.c_void_p(L.SteamAPI_SteamUser_v023())
        L.SteamAPI_ISteamUser_GetSteamID.restype = C.c_uint64
        self.steamid = L.SteamAPI_ISteamUser_GetSteamID(user)
        u = lambda n, res, *args: self._sig("SteamAPI_ISteamUGC_" + n, res, (C.c_void_p,) + args)
        u("CreateItem", C.c_uint64, C.c_uint32, C.c_int)
        u("StartItemUpdate", C.c_uint64, C.c_uint32, C.c_uint64)
        u("SetItemTitle", C.c_bool, C.c_uint64, C.c_char_p)
        u("SetItemDescription", C.c_bool, C.c_uint64, C.c_char_p)
        u("SetItemVisibility", C.c_bool, C.c_uint64, C.c_int)
        u("SetItemTags", C.c_bool, C.c_uint64, C.POINTER(StringArray), C.c_bool)
        u("SetItemContent", C.c_bool, C.c_uint64, C.c_char_p)
        u("SetItemPreview", C.c_bool, C.c_uint64, C.c_char_p)
        u("AddItemPreviewFile", C.c_bool, C.c_uint64, C.c_char_p, C.c_int)
        u("RemoveItemPreview", C.c_bool, C.c_uint64, C.c_uint32)
        u("SubmitItemUpdate", C.c_uint64, C.c_uint64, C.c_char_p)
        u("GetItemUpdateProgress", C.c_int, C.c_uint64, C.POINTER(C.c_uint64), C.POINTER(C.c_uint64))
        u("CreateQueryUGCDetailsRequest", C.c_uint64, C.POINTER(C.c_uint64), C.c_uint32)
        u("SetReturnAdditionalPreviews", C.c_bool, C.c_uint64, C.c_bool)
        u("SendQueryUGCRequest", C.c_uint64, C.c_uint64)
        u("GetQueryUGCNumAdditionalPreviews", C.c_uint32, C.c_uint64, C.c_uint32)
        u("ReleaseQueryUGCRequest", C.c_bool, C.c_uint64)
        u("AddDependency", C.c_uint64, C.c_uint64, C.c_uint64)
        self._sig("SteamAPI_ISteamUtils_IsAPICallCompleted", C.c_bool, (C.c_void_p, C.c_uint64, C.POINTER(C.c_bool)))
        self._sig("SteamAPI_ISteamUtils_GetAPICallResult", C.c_bool,
                  (C.c_void_p, C.c_uint64, C.c_void_p, C.c_int, C.c_int, C.POINTER(C.c_bool)))

    def _sig(self, name, res, args):
        f = getattr(self.lib, name)
        f.restype, f.argtypes = res, list(args)

    def ugc_call(self, name, *args):
        return getattr(self.lib, "SteamAPI_ISteamUGC_" + name)(self.ugc, *args)

    def wait(self, call, struct, cb_id, timeout=600, progress=None):
        failed = C.c_bool(False)
        t0 = time.time()
        while not self.lib.SteamAPI_ISteamUtils_IsAPICallCompleted(self.utils, call, C.byref(failed)):
            self.lib.SteamAPI_RunCallbacks()
            if progress:
                progress()
            if time.time() - t0 > timeout:
                die("Steam did not answer in %d s" % timeout)
            time.sleep(0.2)
        out = struct()
        ok = self.lib.SteamAPI_ISteamUtils_GetAPICallResult(self.utils, call, C.byref(out), C.sizeof(out), cb_id, C.byref(failed))
        if not ok or failed.value:
            die("Steam call failed (callback %d)" % cb_id)
        return out

    def create(self):
        r = self.wait(self.ugc_call("CreateItem", APPID, 0), CreateItemResult, 3403)
        if r.result != 1:
            die("CreateItem: %s" % EResult.get(r.result, r.result))
        if r.needs_legal:
            print("  NOTE: accept the Steam Workshop agreement on the item's page, or nobody else can see it")
        return r.id

    def previews(self, wsid):
        ids = (C.c_uint64 * 1)(int(wsid))
        q = self.ugc_call("CreateQueryUGCDetailsRequest", ids, 1)
        self.ugc_call("SetReturnAdditionalPreviews", q, True)
        r = self.wait(self.ugc_call("SendQueryUGCRequest", q), QueryCompleted, 3401)
        n = self.ugc_call("GetQueryUGCNumAdditionalPreviews", q, 0) if r.result == 1 and r.num >= 1 else 0
        self.ugc_call("ReleaseQueryUGCRequest", q)
        return n

    def update(self, item, note):
        wsid = int(item["id"])
        old = self.previews(wsid)
        h = self.ugc_call("StartItemUpdate", APPID, wsid)
        m = item["meta"]
        ok = [self.ugc_call("SetItemTitle", h, m["title"].encode()),
              self.ugc_call("SetItemDescription", h, m["description"].encode()),
              self.ugc_call("SetItemVisibility", h, 0)]
        tags = [t.encode() for t in item["tags"]]
        arr = StringArray((C.c_char_p * len(tags))(*tags), len(tags))
        ok.append(self.ugc_call("SetItemTags", h, C.byref(arr), False))
        ok.append(self.ugc_call("SetItemContent", h, item["content"].encode()))
        ok.append(self.ugc_call("SetItemPreview", h, item["icon"].encode()))
        for i in range(old - 1, -1, -1):
            ok.append(self.ugc_call("RemoveItemPreview", h, i))
        for g in item["gallery"]:
            ok.append(self.ugc_call("AddItemPreviewFile", h, g.encode(), 0))
        if not all(ok):
            die("%s: Steam refused one of the item's fields" % item["key"])
        call = self.ugc_call("SubmitItemUpdate", h, note.encode())
        last = [None]

        def progress():
            a, b = C.c_uint64(0), C.c_uint64(0)
            st = self.ugc_call("GetItemUpdateProgress", h, C.byref(a), C.byref(b))
            msg = "  uploading: %s %d/%d" % ({1: "preparing", 2: "preparing content", 3: "uploading content",
                                              4: "uploading previews", 5: "committing"}.get(st, "waiting"), a.value, b.value)
            if msg != last[0]:
                print(msg, flush=True)
                last[0] = msg
        r = self.wait(call, SubmitItemUpdateResult, 3404, timeout=1800, progress=progress)
        if r.result != 1:
            die("%s: SubmitItemUpdate: %s" % (item["key"], EResult.get(r.result, r.result)))
        if r.needs_legal:
            print("  NOTE: accept the Steam Workshop agreement on the item's page")
        return old

    def depend(self, parent, child):
        r = self.wait(self.ugc_call("AddDependency", int(parent), int(child)), AddDependencyResult, 3412)
        return r.result in (1, 29)

    def close(self):
        self.lib.SteamAPI_Shutdown()


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("only", nargs="*", choices=[i["key"] for i in ITEMS] + [[]], help="bmx, map, mode (default: all)")
    ap.add_argument("--ref", default="origin/main", help="what to publish from each repo (default origin/main)")
    ap.add_argument("--note", default="", help="the change note (default: the commit's subject)")
    ap.add_argument("--dry-run", action="store_true", help="pack and check, upload nothing")
    ap.add_argument("--yes", action="store_true", help="do not ask first")
    a = ap.parse_args()
    items = [load(dict(i), a.ref) for i in ITEMS if not a.only or i["key"] in a.only]
    for t in (GMAD, STEAM_API_LIB):
        if not os.path.isfile(t):
            die("missing %s (copy it from a Garry's Mod dedicated server's bin/linux64)" % t)

    work = tempfile.mkdtemp(prefix="workshop-sync-")
    try:
        bad = False
        for it in items:
            gma = pack(it, work)
            probs = check(it)
            what = ("update %s" % it["id"]) if it["id"] else "NEW item"
            print("%-5s %-18s %s  %s @ %s  %.1f MB, %d gallery, tags %s" % (
                it["key"], it["meta"]["title"], what, os.path.basename(it["repo"]), it["sha"][:7],
                os.path.getsize(gma) / 1e6, len(it["gallery"]), ",".join(it["tags"])))
            for p in probs:
                print("      PROBLEM: " + p)
                bad = True
        if bad:
            die("fix the problems above first")
        if a.dry_run:
            print("dry run: nothing uploaded")
            return
        if not a.yes and input("Upload these to the Steam Workshop? Type YES: ").strip() != "YES":
            print("nothing uploaded")
            return

        steam = Steam()
        print("Steam: signed in as %d" % steam.steamid)
        ids = {}
        for it in items:
            print("== %s" % it["meta"]["title"])
            if not it["id"]:
                it["id"] = str(steam.create())
                with open(it["idfile"], "w") as f:
                    f.write(it["id"] + "\n")
                print("  created item %s (saved to %s: commit it)" % (it["id"], os.path.relpath(it["idfile"], DESKTOP)))
            note = a.note or subprocess.run(["git", "-C", it["repo"], "log", "-1", "--format=%s", it["sha"]],
                                            capture_output=True, text=True).stdout.strip()
            old = steam.update(it, note[:8000])
            ids[it["key"]] = it["id"]
            print("  done: %s, %d gallery images (replaced %d)" % (it["sha"][:7], len(it["gallery"]), old))
            print("  https://steamcommunity.com/sharedfiles/filedetails/?id=%s" % it["id"])
        # Required Items
        all_ids = {i["key"]: (load(dict(i), a.ref)["id"]) for i in ITEMS}
        for it in items:
            for req in it["requires"]:
                if all_ids.get(req):
                    print("  %s requires %s: %s" % (it["key"], req, "ok" if steam.depend(it["id"], all_ids[req]) else "FAILED"))
        steam.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()

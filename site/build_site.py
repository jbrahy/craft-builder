#!/usr/bin/env python3
"""Generate the craft.reach-x.com site from what is on disk.

Reads /srv/craft/state/repos.json (GitHub repo listing), public/builds,
public/upstream and the newest status/<date>.tsv, and writes index.html,
apps/<repo>/index.html and assets/ under public/. Stdlib only. Every value
that came from upstream or the builder is escaped.
"""
import datetime as dt
import html
import json
import os
import shutil
from pathlib import Path

DATA = Path("/srv/craft")
PUBLIC = DATA / "public"
BUILDS = PUBLIC / "builds"
UPSTREAM = PUBLIC / "upstream"
SITE_SRC = Path(__file__).resolve().parent
ORG = "storytold"
BASE_URL = "https://craft.reach-x.com"

e = html.escape


def human_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024


def files_in(d):
    if not d.is_dir():
        return []
    return sorted(
        (f for f in d.iterdir() if f.is_file() and not f.name.startswith(".")),
        key=lambda f: f.name,
    )


def latest_status():
    files = sorted((DATA / "status").glob("*.tsv"))
    if not files:
        return None, {}
    status = {}
    for line in files[-1].read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 4:
            repo, step, result, note = parts
            status.setdefault(repo, {})[step] = (result, note)
    return files[-1].stem, status


def classify(name):
    """Which platform and kind a published file is, for the download buttons."""
    n = name.lower()
    if n == "sha256sums.txt":
        return None
    if "windows" in n:
        return "windows", "Windows x64 (zip)"
    if "macos" in n and "cli" in n:
        return "macos", "macOS command-line tool"
    if n.endswith(".dmg"):
        return "macos", "macOS (dmg)"
    if n.endswith(".appimage"):
        return "linux", "Linux AppImage"
    if n.endswith(".deb"):
        return "linux", "Debian / Ubuntu (deb)"
    if n.endswith(".rpm"):
        return "linux", "Fedora / RHEL (rpm)"
    if n.endswith(".tar.gz") and "linux" in n:
        return "linux", "Linux (tar.gz)"
    return None


def app_data(repo, meta, status):
    latest = BUILDS / repo / "latest"
    build_dir = latest.resolve() if latest.exists() else None
    up_latest = UPSTREAM / repo / "latest"
    up_dir = up_latest.resolve() if up_latest.exists() else None
    release = {}
    if up_dir and (up_dir / "release.json").is_file():
        release = json.loads((up_dir / "release.json").read_text())

    downloads = {"windows": [], "linux": [], "macos": []}
    for d, base in ((build_dir, f"builds/{repo}/latest"), (up_dir, f"upstream/{repo}/latest")):
        for f in files_in(d):
            c = classify(f.name)
            if c:
                downloads[c[0]].append(
                    {"href": f"{base}/{f.name}", "label": c[1], "size": human_size(f.stat().st_size)}
                )
    today = status.get(repo, {})
    return {
        "repo": repo,
        "description": meta.get("description") or "",
        "pushed_at": (meta.get("pushed_at") or "")[:10],
        "stars": meta.get("stargazers_count", 0),
        "build": build_dir.name if build_dir else None,
        "release": release.get("tag_name") or (up_dir.name if up_dir else None),
        "downloads": downloads,
        "result": {p: today.get(p) for p in ("linux", "windows", "macos", "build", "mirror")},
    }


def tile_state(a):
    """Overall state for the proof strip: built, partial, failed, upstream, mirror."""
    r = a["result"]
    lin, win = r["linux"], r["windows"]
    if lin or win:
        oks = [x for x in (lin, win) if x and x[0] == "ok"]
        if len(oks) == 2:
            return "built", "built tonight on Linux and Windows"
        if oks:
            return "partial", "built tonight on one platform"
        return "failed", "build failed tonight"
    if r["build"] and r["build"][0] == "skip":
        return "built", "unchanged since the last good build"
    if a["release"]:
        return "upstream", "upstream release only"
    return "mirror", "source mirror only"


def page(title, body, desc="Nightly builds of the Crafting Apps, mirrored for Reach X."):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<link rel="stylesheet" href="/assets/site.css">
<script src="/assets/site.js" defer></script>
</head>
<body>
{body}
<footer class="foot">
  <p>Source: <a href="https://github.com/{ORG}">github.com/{ORG}</a>, Apache-2.0 unless the repo says otherwise.
  Linux and Windows files are built here from source and are not code-signed, so Windows will warn before running them.
  macOS files are upstream's signed releases, copied after checking their SHA-256 sums.</p>
  <p>These are independent open-source projects. Neither Reach X nor the authors are affiliated with Adobe, Microsoft, Autodesk or Avid.</p>
</footer>
</body>
</html>
"""


PLATFORM_NAMES = {"windows": "Windows", "linux": "Linux", "macos": "macOS"}


def download_block(a):
    groups = []
    for plat in ("windows", "macos", "linux"):
        items = a["downloads"][plat]
        if not items:
            res = a["result"].get(plat)
            why = "Tonight's build failed." if res and res[0] == "fail" else "No build for this platform."
            groups.append(
                f'<div class="dl" data-platform="{plat}"><h4>{PLATFORM_NAMES[plat]}</h4>'
                f'<p class="none">{why}</p></div>'
            )
            continue
        links = "".join(
            f'<a class="file" href="/{e(i["href"])}" download><span>{e(i["label"])}</span>'
            f'<span class="size">{e(i["size"])}</span></a>'
            for i in items
        )
        groups.append(f'<div class="dl" data-platform="{plat}"><h4>{PLATFORM_NAMES[plat]}</h4>{links}</div>')
    return f'<div class="dls">{"".join(groups)}</div>'


def render_index(apps, others, run_date, status):
    all_tiles = apps + others
    tiles = "".join(
        f'<a class="tile {s}" href="#{e(a["repo"])}" title="{e(a["repo"])}: {e(why)}">'
        f'<span class="sr">{e(a["repo"])}: {e(why)}</span></a>'
        for a in all_tiles
        for s, why in [tile_state(a)]
    )
    counts = {}
    for a in all_tiles:
        counts[tile_state(a)[0]] = counts.get(tile_state(a)[0], 0) + 1
    app_ok = sum(1 for a in apps if tile_state(a)[0] == "built")
    builder = status.get("-", {}).get("builder")
    run_line = f"Last run {e(run_date)}." if run_date else "No nightly run yet."
    if builder and builder[0] == "fail":
        run_line += f" Builder problem: {e(builder[1])}."

    rows = []
    for a in apps:
        state, why = tile_state(a)
        meta = []
        if a["release"]:
            meta.append(f'Upstream {e(a["release"])}')
        if a["build"]:
            meta.append(f'Our build {e(a["build"])}')
        rows.append(f"""
<section class="app" id="{e(a['repo'])}">
  <div class="app-head">
    <span class="swatch {state}" title="{e(why)}"></span>
    <h3><a href="/apps/{e(a['repo'])}/">{e(a['repo'])}</a></h3>
    <p class="desc">{e(a['description'])}</p>
    <p class="meta">{" / ".join(meta)}</p>
  </div>
  {download_block(a)}
</section>""")

    other_rows = "".join(
        f'<tr id="{e(o["repo"])}"><td><span class="swatch small {tile_state(o)[0]}"></span>{e(o["repo"])}</td>'
        f'<td>{e(o["pushed_at"])}</td><td>{e(tile_state(o)[1])}</td>'
        f'<td><code>git clone {BASE_URL}/git/{e(o["repo"])}.git</code></td></tr>'
        for o in others
    )

    body = f"""
<header class="top">
  <h1>Crafting Apps</h1>
  <p class="lede">Open-source rebuilds of the big creative and office tools, compiled every night for Windows and Linux,
  with upstream's macOS releases alongside. {run_line}</p>
</header>

<section class="proof" aria-label="Tonight's results, one tile per repository">
  <div class="strip">{tiles}</div>
  <ul class="legend">
    <li><span class="swatch built"></span>Built ({counts.get("built", 0)})</li>
    <li><span class="swatch partial"></span>One platform ({counts.get("partial", 0)})</li>
    <li><span class="swatch failed"></span>Failed ({counts.get("failed", 0)})</li>
    <li><span class="swatch upstream"></span>Upstream release only ({counts.get("upstream", 0)})</li>
    <li><span class="swatch mirror"></span>Source only ({counts.get("mirror", 0)})</li>
  </ul>
  <p class="summary">{app_ok} of {len(apps)} apps have a current build.</p>
</section>

<main>
  <h2>Apps</h2>
  <p class="platform-note" hidden>Showing <strong data-os-name></strong> downloads first.
  <button type="button" data-show-all>Show every platform</button></p>
  {"".join(rows)}

  <h2>Other repositories</h2>
  <p>Mirrored nightly. Clone any of them from here.</p>
  <div class="table-wrap"><table class="others">
    <thead><tr><th>Repository</th><th>Last change</th><th>Tonight</th><th>Clone</th></tr></thead>
    <tbody>{other_rows}</tbody>
  </table></div>
</main>
"""
    return page("Crafting Apps: nightly builds", body)


def render_app(a):
    repo = a["repo"]
    builds = sorted(
        (d for d in (BUILDS / repo).glob("*-*") if d.is_dir() and not d.is_symlink()),
        key=lambda d: d.name,
        reverse=True,
    ) if (BUILDS / repo).is_dir() else []
    ups = sorted(
        (d for d in (UPSTREAM / repo).iterdir() if d.is_dir() and not d.is_symlink()),
        key=lambda d: d.name,
        reverse=True,
    ) if (UPSTREAM / repo).is_dir() else []

    def listing(d, base):
        sums = {}
        s = d / "SHA256SUMS.txt"
        if s.is_file():
            for line in s.read_text().splitlines():
                parts = line.split()
                if len(parts) == 2:
                    sums[parts[1].lstrip("*")] = parts[0]
        items = "".join(
            f'<li><a href="/{base}/{e(d.name)}/{e(f.name)}">{e(f.name)}</a>'
            f'<span class="size">{human_size(f.stat().st_size)}</span>'
            f'{f"<code class=sum>{e(sums[f.name])}</code>" if f.name in sums else ""}</li>'
            for f in files_in(d)
            if f.name != "release.json"
        )
        return f"<ul class=files>{items}</ul>"

    hist = "".join(
        f'<section class="build"><h3>{e(d.name)}</h3>{listing(d, f"builds/{e(repo)}")}</section>'
        for d in builds
    ) or "<p>No builds from this server yet.</p>"
    up = "".join(
        f'<section class="build"><h3>{e(d.name)}</h3>{listing(d, f"upstream/{e(repo)}")}</section>'
        for d in ups
    ) or "<p>No upstream macOS release mirrored.</p>"

    state, why = tile_state(a)
    body = f"""
<header class="top">
  <p class="crumb"><a href="/">Crafting Apps</a></p>
  <h1><span class="swatch {state}" title="{e(why)}"></span>{e(repo)}</h1>
  <p class="lede">{e(a['description'])}</p>
  <p>Source: <a href="https://github.com/{ORG}/{e(repo)}">github.com/{ORG}/{e(repo)}</a>.
  Clone the mirror: <code>git clone {BASE_URL}/git/{e(repo)}.git</code></p>
</header>
<main>
  <h2>Download</h2>
  {download_block(a)}
  <h2>Our builds</h2>
  <p>Built here from source, newest first. The last 7 are kept.</p>
  {hist}
  <h2>Upstream macOS releases</h2>
  <p>Copied from GitHub after checking upstream's SHA-256 sums. The last 3 are kept.</p>
  {up}
</main>
"""
    return page(f"{repo}: Crafting Apps", body, a["description"] or repo)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def main():
    repos_json = DATA / "state" / "repos.json"
    meta = {r["name"]: r for r in json.loads(repos_json.read_text())} if repos_json.exists() else {}
    run_date, status = latest_status()
    names = sorted(set(meta) | {p.name for p in BUILDS.iterdir() if p.is_dir()} if BUILDS.is_dir() else set(meta))

    every = [app_data(r, meta.get(r, {}), status) for r in names]
    # An "app" is a desktop app with downloads people can use today.
    apps = [a for a in every if a["release"] or any(a["downloads"].values())]
    apps.sort(key=lambda a: (-a["stars"], a["repo"]))
    others = [a for a in every if a not in apps]

    assets = PUBLIC / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    for f in (SITE_SRC / "assets").iterdir():
        shutil.copyfile(f, assets / f.name)
    for name, src in (
        ("overpass.otf", "/usr/share/fonts/opentype/overpass/overpass-regular.otf"),
        ("overpass-bold.otf", "/usr/share/fonts/opentype/overpass/overpass-bold.otf"),
        ("overpass-heavy.otf", "/usr/share/fonts/opentype/overpass/overpass-heavy.otf"),
        ("overpass-mono.otf", "/usr/share/fonts/opentype/overpass/overpass-mono-regular.otf"),
    ):
        if Path(src).is_file():
            shutil.copyfile(src, assets / name)

    write(PUBLIC / "index.html", render_index(apps, others, run_date, status))
    for a in apps:
        write(PUBLIC / "apps" / a["repo"] / "index.html", render_app(a))
    print(f"site: {len(apps)} apps, {len(others)} other repos, run {run_date}")


if __name__ == "__main__":
    main()

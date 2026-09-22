#!/usr/bin/env python3
"""Emit the SideStore/AltStore source feed and a small landing page.

Build facts come from the environment, so the workflow stays the single source
of truth for version, size and download URL.
"""
import datetime as dt
import json
import os
import sys

DESCRIPTION = (
    "Ein lokaler Hörbuch-Player. Importiere ein ZIP-Archiv mit den Kapiteln "
    "als MP3 und höre los: Kapitelübersicht, automatischer Übergang ins "
    "nächste Kapitel, gespeicherte Hörposition, 30-Sekunden-Sprünge, "
    "Geschwindigkeit, Schlummer-Timer, Clips, Auto-Modus und Sperrbildschirm-"
    "Steuerung.\n\n"
    "Alles bleibt auf dem Gerät: keine Konten, keine Netzwerkzugriffe, "
    "keine Analyse."
)


def main(out_dir):
    repo = os.environ["GITHUB_REPOSITORY"]
    owner, name = repo.split("/")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    version = os.environ["VERSION"]
    tag = os.environ["TAG"]
    size = int(os.environ["SIZE"])
    sha256 = os.environ["SHA256"]

    # Pages serves the default branch, and that is where the feed is committed,
    # so every asset URL hangs off it.
    branch = os.environ.get("DEFAULT_BRANCH") or "main"
    pages_site = os.environ.get("PAGES_URL", "").strip().rstrip("/")
    pages_base = pages_site or f"https://{owner.lower()}.github.io/{name}"
    raw_base = f"https://raw.githubusercontent.com/{repo}/{branch}"
    # Assets go over raw.githubusercontent.com so the feed works before GitHub
    # Pages is switched on for the repository.
    icon_url = f"{raw_base}/icon.png"
    download_url = f"{server}/{repo}/releases/download/{tag}/Audioble.ipa"
    date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    version_entry = {
        "version": version,
        "buildVersion": version.rsplit(".", 1)[-1],
        "date": date,
        "localizedDescription": f"Automatischer Build {tag}.",
        "downloadURL": download_url,
        "size": size,
        "sha256": sha256,
        "minOSVersion": "26.0",
    }

    app = {
        "name": "Audioble",
        "bundleIdentifier": "de.toemeler.Audioble",
        "developerName": owner,
        "subtitle": "Lokaler Hörbuch-Player",
        "localizedDescription": DESCRIPTION,
        "iconURL": icon_url,
        "tintColor": "FFA000",
        "category": "entertainment",
        "screenshots": [],
        "versions": [version_entry],
        # Legacy top-level keys, for clients predating the versions array.
        "version": version,
        "versionDate": date,
        "versionDescription": f"Automatischer Build {tag}.",
        "downloadURL": download_url,
        "size": size,
    }

    source = {
        "name": "Audioble",
        "identifier": f"io.github.{owner.lower()}.audioble",
        "subtitle": "Lokaler Hörbuch-Player",
        "description": DESCRIPTION,
        "iconURL": icon_url,
        "website": f"{server}/{repo}",
        "tintColor": "FFA000",
        "apps": [app],
        "news": [],
    }

    os.makedirs(out_dir, exist_ok=True)
    payload = json.dumps(source, indent=2, ensure_ascii=False)
    # s.json is the short path people type; apps.json is the conventional name.
    for filename in ("s.json", "apps.json"):
        with open(os.path.join(out_dir, filename), "w", encoding="utf-8") as fh:
            fh.write(payload + "\n")

    raw_url = f"{raw_base}/s.json"
    source_url = f"{pages_base}/s.json" if pages_site else raw_url
    with open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(LANDING.format(
            source_url=f"{pages_base}/s.json",
            raw_url=raw_url,
            version=version,
            repo=repo,
            server=server,
        ))

    print(f"source URL: {source_url}")
    print(f"raw URL:    {raw_url}")
    print("Pages: " + (pages_site or "nicht aktiv - die Notes nutzen die raw-URL"))

    # Single source of truth for the URL: the release notes read it back here
    # rather than rebuilding it from the repository name a second time.
    step_output = os.environ.get("GITHUB_OUTPUT")
    if step_output:
        with open(step_output, "a") as fh:
            fh.write(f"source_url={source_url}\n")
            fh.write(f"raw_url={raw_url}\n")
            fh.write(f"pages_url={pages_site}\n")


LANDING = """<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Audioble source</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 34rem;
         margin: 0 auto; padding: 3rem 1.25rem; background: #010E19; color: #fff; }}
  code {{ background: rgba(255,255,255,.12); padding: .15em .4em; border-radius: .3em;
          word-break: break-all; }}
  a.btn {{ display: inline-block; background: #FFA000; color: #010E19; text-decoration: none;
           padding: .7em 1.2em; border-radius: .6em; font-weight: 700; }}
  a {{ color: #FFA000; }}
</style>
</head>
<body>
<h1>Audioble</h1>
<p>SideStore-/AltStore-Quelle für unsignierte Audioble-Builds. Aktuelle Version
   <strong>{version}</strong>.</p>
<p><a class="btn" href="sidestore://source?url={source_url}">Zu SideStore hinzufügen</a></p>
<p>Oder diese URL in SideStore &rarr; Sources &rarr; + einfügen:</p>
<p><code>{source_url}</code></p>
<p>Funktioniert auch ohne GitHub Pages:</p>
<p><code>{raw_url}</code></p>
<p><a href="{server}/{repo}">Quellcode und Releases</a></p>
</body>
</html>
"""


if __name__ == "__main__":
    main(sys.argv[1])

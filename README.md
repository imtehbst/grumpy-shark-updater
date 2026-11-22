<p align="center"><img src="art/icon.png" width="96" alt="Grumpy Shark"></p>

# Grumpy Shark Addon Updater

A free, ad-free addon updater for **World of Warcraft: Forever**, for Windows. Keeps your addons fresh. Grumbles about it.

It downloads updates straight from where the addon authors publish them: **GitHub releases**, **CurseForge** and **WoWInterface**. No account, no ads, nothing running in the background.

## Install

1. Click the green **Code** button on this page → **Download ZIP**.
2. Unzip it somewhere you'll keep it, for example `Documents\Grumpy Shark Updater`.
3. Double-click **`Setup.cmd`**. It puts a **Grumpy Shark Updater** shortcut on your desktop.
4. Open the shortcut. It finds your WoW folder by itself (or click **Change folder**).
5. Click **Find my addons**, tick the ones you want kept updated, and click **Add ticked**.

That's it. From then on, open it and click **Update now** whenever it says updates are waiting.

## Using it

| | |
|---|---|
| **Update** tick box | Untick an addon to keep it on the version you have. |
| **Update now** | Installs every ticked addon that has a new version. |
| **Undo last update** | Puts back the versions from before your last update. Old copies are kept in the `backups` folder (last 3 updates). |
| **Find my addons** | Looks through your AddOns folder for addons it knows how to update. |
| GitHub link box | In the Find my addons window: add an addon that's only on GitHub by pasting its link. |
| Right-click a row | **Stop tracking this addon** (its files are left alone). |

WoW can stay open while it updates. Type `/reload` in game afterwards.

**Addons it can't find** aren't published for Forever on GitHub, CurseForge or WoWInterface (for example Wago-only addons). Those are simply left alone. Update them by hand.

Your addon settings (the `WTF` folder) are never touched.

## Updating the updater

When a new version is out, a **"New version available - click to update"** link appears at the top of the window. Click it and say Yes: it updates itself and reopens. Your addon list, backups and any art you added are kept.

On version 1.0.2 or older, the link only opens the download page. Download the new ZIP and unzip it **over your old folder** once; after that, updates are one click.

## Notes

- Windows only (uses the PowerShell that comes with Windows).
- WoW Forever only.
- CurseForge has no free official access for apps like this, so it reads CurseForge's public website data. If CurseForge changes their site, those addons may show "Couldn't check" until this is updated.
- `Update-Addons.ps1` is a text-only version: `-DryRun` shows what would change, `-Restore` undoes the last update.

MIT licensed. Made by imtehbst.

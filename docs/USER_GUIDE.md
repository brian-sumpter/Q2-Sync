# Q2 Sync User Guide

Q2 Sync copies music from Apple Music on your Mac to your Shanling Q2, much like
Finder used to sync an iPod. This guide walks you through everything, step by
step. No technical knowledge needed.

**The most important thing first:** Q2 Sync only *reads* your Apple Music
library. It never changes, moves or deletes anything in your library or its
music files. It only copies music **to** your Q2.

---

## Contents

1. [Connect your Q2 (USB Storage)](#1-connect-your-q2-usb-storage)
2. [First launch](#2-first-launch)
3. [Choose what to sync](#3-choose-what-to-sync)
4. [Run a sync](#4-run-a-sync)
5. [Music that's only on the card](#5-music-thats-only-on-the-card)
6. [Update the library on your Q2](#6-update-the-library-on-your-q2)
7. [Auto-sync](#7-auto-sync)
8. [Firmware update notices](#8-firmware-update-notices)
9. [Eject safely](#9-eject-safely)
10. [Frequently asked questions](#10-frequently-asked-questions)

---

## 1. Connect your Q2 (USB Storage)

1. Turn on your Q2.
2. Swipe **down** from the top of the Q2's screen to open the quick-access menu.
3. Set the USB switch to **USB Storage** (not USB Audio or USB DAC).
4. Connect the Q2 to your Mac with its USB-C cable.

The Q2's microSD card appears on your Mac like a USB stick. You can also put
the card in a card reader instead.

> **Tip:** Only insert or remove the microSD card while the Q2 is fully shut
> down (not just asleep), or the card can be damaged.

The card must be formatted **exFAT** or **FAT32**. New cards usually are.

---

## 2. First launch

1. Open **Q2 Sync**.
2. A notice titled **Before You Start** explains that Q2 Sync never changes your
   Apple Music library, and reminds you to keep a backup of your Mac (for
   example with Time Machine). Read it and click **I Understand**. You'll only
   see it once.
3. The first time macOS asks whether Q2 Sync may access **Apple Music**, click
   **Allow**. Q2 Sync needs this to *read* your library.
4. When your Q2's card is connected, a window asks **"Is this your Shanling Q2?"**
   - Choose which firmware it runs: **Q2 Pod** or **Shanling (stock)**. If
     you're not sure: Q2 Pod looks like an iPod; stock is Shanling's own look.
   - Click **Continue…**. macOS shows the card in a window: make sure the card
     itself is selected, then click **Grant Access**. This lets Q2 Sync change
     files on this card only.
   - Clicked **Not My Q2** on a drive that is not your Q2? Q2 Sync won't ask
     about it again. Did it by mistake? Open **Q2 Sync › Settings** and
     click **Ask Again About Drives Marked "Not My Q2"**.

From now on, Q2 Sync recognises your card automatically and shows it under
**Devices** in the sidebar, like Finder does.

---

## 3. Choose what to sync

1. Click your Q2 in the sidebar, then the **Music** tab.
2. If you see **Library Not Read Yet**, click **Read Library**.
3. Choose one:
   - **Entire music library**: everything that can be copied, plus all your
     playlists.
   - **Selected artists, albums, genres, and playlists**: tick what you want
     in the **Artists**, **Albums**, **Genres** and **Playlists** tabs. Use the
     **Filter** box to find things quickly.

Everything you tick is combined: a song is synced if its artist, album, genre
or any of its playlists is ticked. When you tick an artist, their new albums
sync automatically next time.

The bar at the bottom shows:

- how many songs and how much space your selection uses;
- **"can't be synced"**: click it to see songs that won't be copied, such as
  songs only in iCloud (Q2 Sync never downloads them; download them in Music
  first if you want them) and protected (DRM) songs;
- the **capacity bar**: your music, music you've unticked, what this sync will
  add, other files, and free space. A warning appears if your selection won't
  fit.

Your choices are saved for this Q2 automatically.

---

## 4. Run a sync

1. Click **Sync** (on your very first sync with a card it says
   **Preview Sync**).
2. Q2 Sync reads your library, checks the card, and shows a **preview** of every
   change: songs to **Add**, **Update** or **Rename**, songs **Already on card**,
   and songs that **Can't sync**.
3. **Your first sync with a card is always just a preview.** Nothing changes.
   Look it over, click **Close**, then click **Sync** again to do it for real.
4. **Removing songs you unticked:** these are listed under **Remove**, but
   nothing is removed unless you tick **Remove the … songs you no longer
   sync**. By default they go to a trash folder on the card rather than being
   deleted. If that's more than 20% of the songs on the card, you'll be asked
   to confirm.
5. Click **Sync**. A progress bar shows what's being copied. You can click
   **Cancel** at any time; songs already copied stay, and the next sync carries
   on where it stopped.
6. When it's done, you'll see **Sync Complete** and the option to **Eject** the
   card or keep it connected (**Not Now**).

Every sync is recorded in a log. Click **Show Log** on the result, or go to
your Q2's **Settings** tab → **Show Sync Logs**.

**Where things go on the card:** music goes in `Music/Artist/Album/`,
playlists in `_explaylist_data/`, and Q2 Sync's own records in a hidden
`.q2sync` folder. Q2 Sync never touches the Q2's own files and folders.

---

## 5. Music that's only on the card

If the card has music that isn't part of what you sync (for example songs you
copied by hand, or songs you've since deleted from Apple Music), the preview
lists them under **On the Card Only**. Nothing happens to them unless you
choose. For each file, pick:

| Choice | What happens |
| --- | --- |
| **Leave on Card** (default) | Nothing. |
| **Copy to Mac** | A copy goes to your **Downloads › Q2 Recovered** folder. The file stays on the card. |
| **Move to Card Trash** | Moved into the card's hidden trash folder (you can still get it back). |
| **Delete from Card** | Deleted for good. You'll be asked to confirm. |

Use **Set all to** to choose for every file at once.

**About "Copy to Mac":** Q2 Sync never puts files into your Music library. It
copies them to **Downloads › Q2 Recovered**, keeping their folders, and lists
them in `RECOVERED.txt`. To add them to Apple Music, open Music and choose
**File › Import…**. Songs already in your library aren't copied again, and
nothing in the Q2 Recovered folder is ever overwritten.

**Emptying the card's trash:** in Finder, open the card, press
**⌘⇧.** (Command-Shift-period) to show hidden folders, and delete `.q2sync/Trash`.

---

## 6. Update the library on your Q2

After every sync, your Q2 needs to scan the card before new music shows up:

1. Eject the card in Q2 Sync, then unplug the Q2.
2. On the Q2:

| Firmware | Steps |
| --- | --- |
| **Q2 Pod** | **Library → Update Library → Scan music now** |
| **Shanling stock** | **Local Songs → Update Library → Scan music now** |

3. To bring in your playlists:

| Firmware | Steps |
| --- | --- |
| **Q2 Pod** | **Library → Playlists → Import** (in the Classic theme, under **Select Playlists…**) |
| **Shanling stock** | Open **Playlists** and choose **Import** |

Importing a playlist with the same name replaces the old one. The Q2 keeps up
to 100 playlists. If you unticked a playlist, delete it on the Q2 too: removing
its file from the card doesn't remove a playlist you already imported.

Q2 Sync shows these steps after each sync, for your Q2's firmware.

---

## 7. Auto-sync

Q2 Sync can notice when your Q2 connects. On your Q2's **Settings** tab, under
**Auto-Sync**, choose **When this Q2 connects**:

- **Ask Me (Notification)** (default): a notification asks whether to sync.
  Click **Sync Now**.
- **Sync Automatically**: syncs straight away.
- **Do Nothing**: you sync by hand.

Automatic syncs follow every safety rule. They **never remove songs and never
eject**. If anything needs your decision (the first sync with a card, songs
you unticked, songs gone from your library, or not enough space), they stop,
open the preview in Q2 Sync, and notify you. When an automatic sync finishes,
a notification has an **Eject** button.

For auto-sync to work, Q2 Sync must be running. It stays in the **menu bar**
when you close its window. To start it automatically, open
**Q2 Sync › Settings** and turn on **Open Q2 Sync at login**.

The **menu bar item** shows whether your Q2 is connected and lets you **Sync
Now**, **Eject**, **Open Q2 Sync**, open **Settings** or **Quit**. You can hide
it in Settings.

---

## 8. Firmware update notices

**Q2 Pod:** on your Q2's **Settings** tab, under **Firmware Updates**, turn on
**Check GitHub for new Q2 Pod releases**. Q2 Sync checks at most once a day
when your Q2 connects (or when you click **Check Now**) and tells you about new
releases, with their notes and a link.

- Q2 Sync can't see which version your Q2 runs, so type it in under
  **Installed version** (on the Q2: **System settings → About**, shown as
  "CFW. Version"). Then it can tell you whether you're up to date.
- If you leave it blank, Q2 Sync tells you about each new release once; click
  **Dismiss** to hide it until the next one.

**Shanling stock:** there's a link to Shanling's download page. Your Q2 can
also check by itself: **System Setting → System Update → Network update**.

Q2 Sync **never downloads or installs firmware**. Follow the release's
instructions to update on the Q2.

---

## 9. Eject safely

Always eject before unplugging:

- click **Eject** on the result after a sync, or
- the eject button next to your Q2 in the sidebar, or the **Eject** button on
  its page, or
- **Eject** in the menu bar item.

If ejecting fails, Q2 Sync says so and the card stays connected. Close any
Finder windows showing the card and try again.

---

## 10. Frequently asked questions

**Can Q2 Sync damage my Apple Music library?**
No. It only reads your library, and macOS itself prevents it from writing to
your Music folder. It still makes sense to keep a backup of your Mac, as with
any app.

**Why are some songs "can't be synced"?**
They're only in iCloud (not downloaded to your Mac) or protected by DRM. Q2 Sync
never downloads songs. Download them in Music first if you want them on your Q2.

**I unticked an album but it's still on my Q2.**
Removals are always your choice. Tick **Remove the … songs you no longer sync**
in the preview.

**I deleted a song in Apple Music. What happens to the copy on the card?**
It's listed under **On the Card Only** with the note "no longer in your
library", so you can copy it back to your Mac or remove it.

**What happens to music I copied onto the card myself?**
It's left alone unless you choose otherwise under **On the Card Only**. Q2 Sync
never overwrites it.

**My new music doesn't show on the Q2.**
Run **Update Library** on the Q2 (see section 6).

**The card is full.**
The capacity bar warns you. Untick some music, or allow removals in the preview.
Q2 Sync always leaves 200 MB free for the Q2's own use.

**What are the `.q2sync` and `_explaylist_data` folders on the card?**
`.q2sync` holds Q2 Sync's record of what it copied, plus the card's trash.
`_explaylist_data` holds playlists for the Q2 to import. Please don't edit
`.q2sync/manifest.json`. If it ever gets damaged, delete it: the next sync
rebuilds it without copying identical songs again.

**Can I use the same card with another Mac?**
Yes. The record of what's on the card lives on the card itself.

**Where are the logs?**
Your Q2's **Settings** tab → **Show Sync Logs**.

**I clicked "Not My Q2" by mistake.**
**Q2 Sync › Settings → Ask Again About Drives Marked "Not My Q2"**.

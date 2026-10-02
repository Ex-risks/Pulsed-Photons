# Installing Pulsed Photons

A step-by-step guide. Follow it in order and do not skip steps 4 and 5.

**Before you start, check your Mac can run it:**

- macOS **14 (Sonoma) or newer**. To check: click the  menu in the top-left
  corner of your screen → **About This Mac**. If the number is 13 or lower,
  this app will not open and no amount of trying will change that.
- Any Mac from 2017 onwards. Apple silicon (M1–M4) and Intel both work.

There are two ways to install. **Route A is for everybody.** Route B is only if
you want to read or change the source code.

---

# Route A — Download the ready-made app

No Xcode, no Terminal (except possibly one line in step 5). About five minutes.

### Step 1 — Go to the Releases page

Open the project on GitHub, and on the right-hand side of the page find the
**Releases** heading. Click it. (Or add `/releases` to the end of the project's
web address.)

You will see a list of versions. The one at the top is the newest.

### Step 2 — Download the app

Underneath the newest version there is a section called **Assets**. Click the
file named:

```
PulsedPhotonsPro.zip
```

> **Do not** click "Source code (zip)" or "Source code (tar.gz)". Those are the
> code, not the app, and they will not run. You want the file whose name starts
> with `PulsedPhotonsPro`.

The download goes to your **Downloads** folder.

### Step 3 — Unzip it and move it to Applications

1. Open your **Downloads** folder.
2. **Double-click** `PulsedPhotonsPro.zip`. It becomes `PulsedPhotonsPro` with a
   dark circular icon. (On most Macs Safari unzips it for you, so you may find
   it already done.)
3. **Drag** `PulsedPhotonsPro` into your **Applications** folder.

### Step 4 — Open it the first time (the important step)

This app is not sold through the Mac App Store and is not signed with a paid
Apple developer certificate, so **macOS will refuse to open it on the first
try.** This is expected. It is not a virus warning and nothing is wrong with
your Mac or with the app.

Do this:

1. Open your **Applications** folder and **double-click** PulsedPhotonsPro.
2. A box appears saying Apple cannot check it for malicious software, or that
   it cannot be opened. Click **Done** or **Cancel**. (There may be no "Open"
   button. That is normal.)
3. Click the  menu → **System Settings**.
4. In the left-hand list, click **Privacy & Security**.
5. **Scroll down** — a fair way down, past a lot of other settings — to the
   **Security** section. You will see a line saying
   *"PulsedPhotonsPro was blocked to protect your Mac."*
6. Click the **Open Anyway** button beside it.
7. Enter your Mac's password (or use Touch ID) when asked.
8. One more box appears. Click **Open Anyway** again.

From now on it opens with a normal double-click, like any other app.

### Step 5 — Only if it says the app is "damaged"

If instead of the message above you get:

> *"PulsedPhotonsPro is damaged and can't be opened. You should move it to the
> Bin."*

the app is **not** damaged. macOS says this about unsigned apps that arrived in
a zip file. Do not move it to the Bin. Do this instead:

1. Press **⌘ Space**, type `Terminal`, press **Return**.
2. Copy the line below and paste it into the Terminal window:

   ```bash
   xattr -dr com.apple.quarantine /Applications/PulsedPhotonsPro.app
   ```

3. Press **Return**. Type your password if asked — the characters will not
   appear as you type, which is normal. Press **Return** again.
4. Nothing will be printed if it worked. Close Terminal and open the app
   normally.

That command removes the "this came from the internet" flag macOS attached to
the download. It changes nothing else.

### Step 6 — Check it works

1. With the app open, drag one of the sample files onto its window, or press
   **⌘O** and choose a file.
   Sample files live in the project's `Samples` folder — `sphere_5k.xyz` is a
   good first test. If you downloaded only the app and not the code, press **⌘O**
   and open any `.ply`, `.xyz`, `.txt` or `.las` scan you have.
2. You should see a cloud of points. **Drag** to orbit it. **Scroll** to zoom.
3. For the full list of what you can do, go to the **Help** menu → **Controls**.

You are done.

---

# Route B — Build it from the source code

Only do this if you want to read or modify the code. You do not need this to
use the app.

**You will need Xcode** — a free download from the Mac App Store, but it is
roughly 10 GB and takes a long while. Start the download before you need it.

### Step 1 — Install Xcode

1. Open the **App Store**, search for **Xcode**, click **Get**.
2. When it finishes, **open Xcode once** and accept the licence agreement. It
   will install some extra components. Let it finish.

### Step 2 — Download the code

**Either** — the simple way:

1. Go to the project's main GitHub page.
2. Click the green **Code** button → **Download ZIP**.
3. Unzip it, and move the folder somewhere sensible like your Documents folder.

**Or** — with Terminal, if you know git:

```bash
git clone https://github.com/Ex-risks/Pulsed-Photons.git
```

### Step 3 — Open and run

1. In the project folder, **double-click** `PulsedPhotonsPro.xcodeproj`. Xcode
   opens.
2. Press **⌘R** (or click the ▶ play button, top-left).
3. The first build takes a minute or two. The app then launches by itself.

You do not need an Apple Developer account and you do not need to change any
signing settings. Xcode signs it to run on your own Mac automatically.

### Step 4 — If Xcode complains about signing

If you see a red error mentioning signing or a development team:

1. Click **PulsedPhotonsPro** at the very top of the left-hand file list.
2. Click the **Signing & Capabilities** tab.
3. Set **Team** to your own name (listed as *Personal Team*), or leave it empty
   and tick **Automatically manage signing**.
4. Press **⌘R** again.

### Running from Terminal instead

If you prefer, the project builds and launches with one command:

```bash
./run.sh
```

---

# Troubleshooting

**"The application can't be opened."**
Your macOS is probably too old. Check  → **About This Mac**. You need 14 or
newer.

**Nothing happens when I double-click the app.**
Go back to Step 4. macOS is blocking it silently. The **Open Anyway** button in
System Settings → Privacy & Security is what you need.

**It opens but the window is blank.**
That is the correct empty state — a blank sheet. Press **⌘O** and open a scan
file.

**My file won't open.**
The app reads `.ply`, `.xyz`, `.txt` and `.las`. Anything else — `.e57`, `.pts`,
`.laz` — needs converting first. Note that `.laz` is the *compressed* form of
`.las` and is not supported; export an uncompressed `.las` from whatever tool
made it.

**It is very slow, or it runs out of memory.**
Large scans are heavy. Lower the **points** value in the bottom band by dragging
the number beside it to the left. This draws fewer points without changing your
file.

---

**Still stuck?** Open an **Issue** on the project's GitHub page — the **Issues**
tab at the top. Say which Mac you have, which macOS version, and which step you
reached.

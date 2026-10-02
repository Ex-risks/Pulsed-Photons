# Installing Pulsed Photons

Pulsed Photons requires:

- macOS 14 Sonoma or newer
- a Mac from 2017 or later
- Apple silicon or Intel

There are two ways to install it:

- **Route A:** download the ready-made app
- **Route B:** build it from source

## Route A: Download the app

Use this if you only want to run Pulsed Photons.

### 1. Download the latest release

Open the project's GitHub **Releases** page.

Under the latest release, download:

```text
PulsedPhotonsPro.zip
```

Do not download the GitHub-generated **Source code** archives.

### 2. Install the app

1. Open your Downloads folder.
2. Unzip `PulsedPhotonsPro.zip`.
3. Drag `PulsedPhotonsPro.app` into your Applications folder.

Safari may unzip the file automatically.

### 3. Open it for the first time

The app is not distributed through the Mac App Store and is not signed with a paid Apple developer certificate, so macOS may block it on first launch.

1. Open **Applications** and double-click `PulsedPhotonsPro`.
2. Dismiss the warning.
3. Open **System Settings → Privacy & Security**.
4. Scroll to **Security**.
5. Find the message saying PulsedPhotonsPro was blocked.
6. Click **Open Anyway**.
7. Authenticate with your password or Touch ID.
8. Click **Open Anyway** again.

After this, the app should open normally.

### 4. If macOS says the app is damaged

If macOS shows:

```text
PulsedPhotonsPro is damaged and can't be opened.
```

Open Terminal and run:

```bash
xattr -dr com.apple.quarantine /Applications/PulsedPhotonsPro.app
```

Then open the app again.

This removes the quarantine attribute added to the downloaded app.

### 5. Test the app

Open a supported point-cloud file by either:

- dragging it onto the app window
- pressing `⌘O`

Supported formats:

- `.las`
- `.ply`
- `.xyz`
- `.txt`

If you downloaded the source repository, `Samples/sphere_5k.xyz` is a simple test file.

Once loaded:

- drag to orbit
- scroll to zoom
- open **Help → Controls** for the full control list

## Route B: Build from source

Use this only if you want to inspect or modify the code.

You will need Xcode.

### 1. Install Xcode

Install Xcode from the Mac App Store.

Open it once after installation and allow any additional components to finish installing.

### 2. Download the source

From GitHub:

1. Open the project page.
2. Click **Code → Download ZIP**.
3. Unzip the project.

Or clone it with Git:

```bash
git clone https://github.com/Ex-risks/Pulsed-Photons.git
```

### 3. Build and run

Open:

```text
PulsedPhotonsPro.xcodeproj
```

Then press:

```text
⌘R
```

Xcode will build and launch the app.

### Signing errors

If Xcode reports a signing or development-team error:

1. Select the `PulsedPhotonsPro` project.
2. Open **Signing & Capabilities**.
3. Enable **Automatically manage signing**.
4. Select your **Personal Team** if required.
5. Press `⌘R` again.

### Run from Terminal

You can also build and launch from the project directory with:

```bash
./run.sh
```

## Troubleshooting

### The application cannot be opened

Check your macOS version under **Apple menu → About This Mac**.

Pulsed Photons requires macOS 14 or newer.

### Nothing happens when I open the app

Go to:

**System Settings → Privacy & Security**

Look for the blocked-app message and click **Open Anyway**.

### The window is blank

That is the normal empty state.

Press `⌘O` or drag a supported point-cloud file into the window.

### My file will not open

Supported formats are:

```text
.las
.ply
.xyz
.txt
```

Formats such as `.e57`, `.pts`, and `.laz` must be converted first.

`.laz` is compressed LAS and is not currently supported.

### Large files are slow

Reduce the **points** value in the bottom bar.

This lowers the number of points drawn without changing the source file.

## Getting help

If the problem continues, open an Issue on GitHub and include:

- your Mac model
- your macOS version
- the step that failed
- any error message shown

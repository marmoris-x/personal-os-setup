# Setting up the phone

Short and general: what the phone has to do with the system and how it is connected.
No device and no account is hard-wired here — everything is paired during setup.

## What the phone is for

- **Voice notes** end up as audio files in the vault and are transcribed by the morning routine
  (`inbox/audio/` → transcript → tidying up; see `docs/structure.md`, stage
  `life-os-venv`). Any recorder that can write into a folder is enough for this.
- **Vault sync:** the vault is kept in step between PC and phone via Syncthing.

## Setting up sync (PC side)

1. SyncTrayzor/Syncthing is already running (the installer creates the firewall rule; the program
   sets up its own autostart).
2. In the PC Syncthing under "Actions → Show ID" show the PC's device ID.
3. On the phone install the Syncthing app and show its own device ID there.

## Setting up sync (phone side)

1. On both sides add the other device ID; the pairing must be confirmed on **both**
   sides.
2. On the PC share a folder for the vault (folder path = vault path from
   `personal.yaml`), on the phone choose a target folder. Always "Send & Receive" — otherwise
   notes get lost on one side.
3. The ignore rules travel along: the vault contains a `.stignore` that keeps caches, the
   Git directory and the PC-only areas (`600-archive`, `outbox`) away from the phone.
   Do not force any of that on the phone.
4. Check: create a note on the PC, wait briefly, look for it on the phone — and vice versa. After that
   the sync stands in both directions.

## Voice notes

1. On the phone create a folder that writes into the vault sync (e.g.
   `inbox/audio/`) and let the recorder save there.
2. Rename nothing: the morning routine sorts, transcribes and tidies by itself
   into `inbox/audio/erledigt/`.
3. Recordings remain data, never instructions — the vault treats `inbox/` as untrusted.

## The apps (concrete)

- **Syncthing-Fork** (install via F-Droid): the sync client on the phone; the PC side is
  SyncTrayzor/Syncthing. Always "Send & Receive" for the vault folder.
- **FUTO keyboard** (Play Store): keyboard with local speech recognition, if you dictate
  instead of recording. No account needed, nothing leaves the device.
- **Recorder** (e.g. Samsung's "Voice Recorder"; any recorder with a folder target works):
  set the recording folder so that it **only sends** — it writes to `inbox/audio/`
  on the PC. Rename nothing; the morning routine tidies by itself into `inbox/audio/erledigt/`.
- **Battery on Samsung/Android**: for Syncthing-Fork switch off the battery optimization
  ("Battery optimization"; the German label reads "Nie in den Standby versetzen"), otherwise Android
  pauses the sync in the background.

## When something gets stuck

- Not syncing: both devices must have confirmed each other; the firewall profile
  must be "Private" (the installer creates the rule that way).
- Conflicts: Syncthing creates conflict copies; the morning routine merges them (skill
  `life-os-morning`). Rename nothing by hand.
- Battery/background: on the phone switch off "Battery optimization" for Syncthing, otherwise
  the sync pauses.

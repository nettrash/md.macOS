# Privacy Policy

**Effective date:** 29 June 2026
**Applies to:** md for macOS — the native Mac Markdown editor published by
nettrash. This policy is versioned alongside the app's source code; the
most recent commit on `main` is authoritative.

## TL;DR

md **does not collect, transmit, sell, or share any data.** It contains
no analytics, no advertising SDKs, no third-party trackers, and no
servers operated by us. The documents you open and edit stay where you
put them — on your Mac or in your own iCloud Drive.

If that already answers your question, you don't need to read the rest.

## What we collect

**Nothing.** md has no account to create, no email to register, and no
telemetry. It contacts no servers of ours — there are none. The one time
the app touches the network at all is when a document you opened points at
an image by remote URL, and the renderer fetches that image so it can be
shown and printed (see **Permissions** below).

## Your documents

md is a document editor. The files you open, create and save are handled
entirely by Apple's system document architecture and are stored wherever
you choose — locally or in iCloud Drive. We never see them. If you store a
document in iCloud Drive, it syncs through *your* Apple account under
Apple's privacy terms, not ours.

The app stores a few small settings on your Mac, through the standard
system preferences and window-restoration stores: your last-used
Edit / Split / Preview layout, whether a book opens its articles in
separate windows and — if you use writer mode — a security-scoped bookmark
to the book folder you chose, plus which article in it you had open last,
so the book reopens where you left it. A security-scoped bookmark is
simply how a sandboxed app is permitted to reopen a folder you picked; it
points at a place on your own Mac and never leaves it. **File ▸ Close
Book** discards it. None of these settings leave your Mac, and none of
them contain personal information.

## Permissions

md requests no special permissions — no camera, microphone, contacts, or
location. The app runs in the macOS **App Sandbox** and requests only
user-selected file access
(`com.apple.security.files.user-selected.read-write`): it can read and
write the documents you explicitly open or save, and nothing else.

The sandbox also carries the network-client entitlement
(`com.apple.security.network.client`). Two things need it. First, the
built-in web renderer that draws the preview and produces the Print / PDF /
EPUB output will not launch inside the App Sandbox without it. Second, if a
document you open references an image by remote URL
(`![alt](https://…)`), the renderer fetches that image so it can be shown
and printed — that request goes straight to the host **your own document
names**, which sees your IP address exactly as it would if you opened the
link in a browser. It happens only for documents that contain such a link.

Everything else is built on your Mac: the Markdown renderer, and the math
and diagram engines (KaTeX, Mermaid, Graphviz, PlantUML) are bundled inside
the app and run offline. md sends no data anywhere, and contacts no servers
of ours, because there are none.

## Children's privacy

Because md collects no data at all, it collects no data from children.

## Changes to this policy

Any change is committed to this file in the app's public source
repository, so the history is auditable.

## Contact

Questions: <nettrash@nettrash.me>.

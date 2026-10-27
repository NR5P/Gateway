# XaraMail: an open-source Winlink client for iPhone

XaraMail sends and receives Winlink radio email from an iPhone. Over the air it talks to a
Winlink gateway (RMS) through a **VARA modem over TCP**: [xara](../xara) running on the same
phone (`127.0.0.1`), or xara/VARA on a computer on your network. It can also reach the Winlink
CMS over the internet by telnet.

<p>
<img src="docs/connected.png" width="280" alt="Connect screen, linked to a gateway over VARA HF">
<img src="docs/inbox.png" width="280" alt="Inbox with a message received over the link">
</p>

- **Mail**: Inbox, Outbox, Sent, Drafts; compose with To/Cc/Subject/body and file attachments;
  reply, reply-all, forward; attachments open through the share sheet.
- **Connect**: VARA HF (500/2300/2750 Hz) or VARA FM, gateway call sign (recent ones are
  remembered), live PTT/BUSY/link state, transfer progress, Abort; or Telnet to the CMS.
- **Settings**: call sign, grid locator, Winlink password (iOS Keychain, this device only),
  modem host and command port (data port = command port + 1), CMS host/port.
- **Session log**: B2F protocol lines and modem commands, shareable.

It is MIT-licensed and has no third-party dependencies.

## Why a Swift port and not gomobile

Pat (Go) and its protocol library [wl2k-go](https://github.com/la5nta/wl2k-go) are the mature
open-source Winlink stack, and both are MIT-licensed (no GPL, so App Store distribution is fine).
I ported the parts a client needs to Swift (`WinlinkKit`) instead of embedding Go with gomobile:

- The protocol part is small: the `fbb` package (B2F forwarding, message format, secure login)
  is about 2,500 lines of Go with comments, and `lzhuf` about 900. The Swift library is about
  2,500 lines including the VARA and telnet transports.
- gomobile would add a Go toolchain, a ~10 MB xcframework and a cgo bridge to every build, plus
  Go's own goroutine/network runtime on iOS, for code that is mostly string handling.
- A native port lets the transports use Network.framework and Swift concurrency directly, and the
  library and its tests build with plain `swift test`.

wl2k-go's own test vectors were ported too (see below), so the port can be checked against it.
The VARA command sequence follows Pat's VARA driver
([Pat-Vara](https://github.com/n8jja/Pat-Vara), MIT). Licence texts for the ported code are in
`WinlinkKit/LICENSE.wl2k-go` and `WinlinkKit/COPYRIGHT.lzhuf`.

## Layout

```
XaraMail.xcodeproj      iOS 17+ app, Swift 5 mode, team G4GK5372G8, bundle id com.nr5p.xaramail
XaraMail/               SwiftUI app: mail store, session controller, views
WinlinkKit/             Swift package: the protocol and transports
  Sources/WinlinkKit/
    LZHUF.swift           LZHUF compression with the B2 CRC16 header
    Message.swift         Winlink message format, addresses, RFC 2047 words, MIDs
    Proposal.swift        FC proposals, FS answers, secure login response
    B2FSession.swift      the B2F exchange (client or master)
    VARAModem.swift       VARA command/data port client (CONNECT, LISTEN, BUFFER, PTT, ...)
    TCPStream.swift       Network.framework TCP
    Telnet.swift          CMS telnet login
  Sources/TestGateway/  `test-gateway`: a stand-in RMS that answers VARA calls (macOS)
  Tests/                unit tests and live-xara integration tests
tools/xara-airlink/     two xara modems linked by simulated audio, for end-to-end tests
```

## Using it with xara

**On the same phone.** Start the xara iOS app (it keeps running in the background with
background audio), connect the radio interface, then in XaraMail:

1. Settings: your call sign, grid, Winlink password. Modem host `127.0.0.1`, port `8300`.
2. Compose a message; it waits in the Outbox.
3. Connect: VARA HF (or FM), the gateway's call sign (e.g. from the Winlink RMS list), bandwidth,
   then **Connect**. The app sends `MYCALL`, `BW…`, `CONNECT <you> <gateway>`, waits for
   `CONNECTED`, runs the B2F exchange (secure login, sends your Outbox, downloads your mail), and
   disconnects.

Keep XaraMail in the foreground while it is connected (it keeps the screen awake); iOS suspends
apps that are not playing audio, and a suspended client drops the session.

**On another computer.** Run xara (or VARA) there with its command port reachable on the LAN,
e.g. `xara --call YOURCALL --hf 2300 --addr 0.0.0.0 --port 8300 ...`, and set the modem host in
Settings to that machine's address. iOS asks for local-network permission the first time.

**Telnet.** Pick *Telnet (internet)* on the Connect tab: it logs in to `server.winlink.org:8772`
and runs the same exchange with no radio.

## What was tested, and how

All of this runs on a Mac; `swift test` needs nothing else.

| What | How | Result |
|---|---|---|
| LZHUF | wl2k-go's vectors: 4 inline samples and 5 files (Gettysburg, e, pi, a real B2F message, *Tom Sawyer*), compressed and decompressed **byte-for-byte** against the reference `.lzh` files; bad CRC, truncation, no-CRC mode | pass |
| Secure login | wl2k-go's vectors (`23753528`/`FOOBAR` → `72768415`, `FooBar` → `95074758`) | pass |
| B2F protocol | wl2k-go's session tests against a scripted CMS (handshake lines, `FS =` deferral, CMS v4 `;PM`/`;WARNING` lines), `FS` answer parsing incl. offsets, proposal sorting by precedence, `;FW`/`;PM` parsing, login-failure detection; plus a byte-level scripted gateway exchange (proposal checksum, SOH/STX/EOT framing, an inbound message with a non-ASCII subject and an attachment) and a P2P exchange between two of our own sessions | pass |
| Message format | wire format, header order, RFC 2047 subjects/file names (Q and B, ISO-8859-1 and UTF-8, raw Latin-1), date layouts, address forms, validation | pass |
| Telnet login | CMS prompts against a scripted server, including bytes arriving with the password prompt | pass |
| VARA client vs the **real xara binary** | `XARA_CMD_PORT=18300 swift test`: `VERSION` (`VARA HF v4.9.0`), `PUBLIC`/`CWID`/`COMPRESSION`/`MYCALL`/`LISTEN OFF`/`BW2300`/`WINLINK SESSION` all `OK`, `CONNECT` keys the transmitter (`PTT ON`), cancel sends `ABORT`, modem back to idle | pass |
| **B2F over a VARA ARQ link between two xara modems** | `tools/xara-airlink` links two xara modems through simulated audio, each with real VARA TCP ports. Our client calls N2TST, our master-side session answers through `LISTEN ON`, and a message goes each way (one with an attachment), with `BUFFER` flow control and `DISCONNECT`/`DISCONNECTED` | pass (~2 min) |
| **The app in the iOS simulator** | XaraMail (iPhone 17 Pro, iOS 27) on the airlink against `test-gateway --password SECRET`: the call linked (`CONNECTED N0TST N1RMS 2300`). With a wrong password the gateway refused the secure login and the app said *Login failed*. With the right one, the message composed in the app was delivered, the gateway's message arrived in the Inbox, and the Outbox emptied | pass |
| Builds | `xcodebuild` for iOS Simulator and for a device (signed with team G4GK5372G8) | pass |

### Running the tests

```sh
cd WinlinkKit && swift test            # unit tests; live-modem tests are skipped
```

Against xara (from `~/Desktop/xara`, after `cargo build --release -p xara`):

```sh
./target/release/xara --call N1TST --capture NMAudioDevice_UID --playback NMAudioDevice_UID --port 18300 --kiss-port off
```

```sh
cd tools/xara-airlink && cargo build --release && ./target/release/xara-airlink 18500 18600
```

```sh
cd WinlinkKit && XARA_CMD_PORT=18300 XARA_AIRLINK=18500,18600 swift test
```

To try the app against the airlink, run a stand-in gateway on station B and point the app
(Settings → port `18500`, gateway `N1RMS`) at station A:

```sh
cd WinlinkKit && swift run test-gateway --call N1RMS --port 18600 --password SECRET
```

`xara-airlink` expects the xara source tree next to this repository (`../xara`). Two real xara
processes sharing the NoMachine virtual audio device hear each other but never finish the
handshake, which is why the airlink tool exists.

## Not tested

- **A real over-the-air session with an RMS.** That needs a radio, an interface (e.g. Digirig),
  a licence, a Winlink account and a gateway in range. Everything up to the audio is tested above;
  the gateway side was our own B2F master, not RMS Trimode.
- **The live Winlink CMS**, over telnet or through a gateway. Only scripted CMS sessions were run.
  The first real login will show whether the CMS accepts the `XaraMail` SID.
- **xara running on the same iPhone**, with both apps switching between foreground and background.
  In the simulator the app reached xara on the Mac through `127.0.0.1`.
- **Real VARA (Windows).** The client only does what Pat does, and it treats a missing reply to
  `PUBLIC`/`CWID`/`COMPRESSION`/`LISTEN` as harmless, but it was only run against xara.
- **VARA FM against xara**, P2P sessions from the app, and B2F resume offsets (parsed and honoured
  when sending, never requested when receiving, as in wl2k-go).
- Gzip (`FD`) proposals are deferred, as in wl2k-go unless its experiment flag is set.

## Notes

- The B2F SID sent is `[XaraMail-<version>-B2FHM$]`.
- Messages are stored as raw B2F files under Application Support/Mail/<folder>.
- `WinlinkKit` builds with `-O` even in Debug, because LZHUF walks a tree for every byte.

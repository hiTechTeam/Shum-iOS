# Seed profiles and offline invitations

The current identity model has one active writer per identity. Simultaneous
editing from multiple devices sharing private keys is not supported.

## Authenticated profile

`ShumContactCard` keeps the legacy identity signature for the push API and old
cards. New cards additionally sign the full public profile using the domain
`shum.profile.v1\0`. The signature binds identity keys, name, bio, avatar seed,
generator version and a positive UInt64 profile revision. Signature fields are
excluded from this canonical payload. Its SHA-256 digest (`profileID`) identifies
the content independently of signature randomness.

The owning device persists its signed head in the encrypted conversation store,
alongside the delivery outbox. Profile changes increment the revision, coalesce
pending deliveries and commit to disk before publishing the new head. The existing
backup includes this file. A peer holding a newer signed head after backup restore
causes the current local choice to be reissued above the observed revision.

Every incoming profile is authenticated and merged against pinned identity keys.
Higher revisions win; equal-revision conflicts use the canonical profile digest
as a deterministic tie-break. Legacy unversioned cards cannot replace versioned
cards. Contacts, encounters, requests and nearby discovery use the same merge.
Historical message envelopes retain their original signed snapshots.

## QR and links

Self-contained invitation payloads are `shum://c4/<base64url>`. The compact binary payload contains:

- format byte 4, contact-card version byte
- 32-byte Noise, signing and Nostr public keys
- one-byte UTF-8 name length and name
- two-byte big-endian UTF-8 bio length and bio
- little-endian UInt64 avatar seed, one-byte generator version
- little-endian UInt64 profile revision
- one 64-byte signature over the complete public profile

The profile QR code and shared links carry the same c4 payload. It holds the
keys, name and avatar seed, but no image. Adding a contact from it needs no
network at all: the receiver checks the signature, draws the avatar on the
device and asks whether to save the contact. Saving a contact does not accept
a chat invitation. The QR code uses error correction level M so it still scans
with the logo in the middle.

Shared links use `/invite#c4/<same-payload>` on the configured HTTPS gateway.
The part after `#` never reaches the web server. Opening the page in a browser
needs internet, but the app itself does not.

A c4 code is a snapshot of the profile at the moment it was shared. Later
changes reach saved contacts through profile sync (see Delivery). Older `c`,
`c2`, `c3` and `contact` codes can still be read; `c2` holds only a key, so it
needs an internet lookup.

## Delivery

`ShumProfileSync` is domain-signed and transported through the existing encrypted
BLE/Nostr paths. It carries the sender profile, recipient identity, the newest
known recipient profile and a reply flag. The response acknowledges the exact
profile content only after saving it. Relay acceptance never clears the outbox.

Pending updates survive restart, retry with bounded exponential backoff (up to
one hour), and use both available routes. Replies do not request another reply.
Startup/foreground reconciliation queries existing contacts; blocked or removed
contacts are excluded. Messages, invitations, presence and typing also merge
verified profile snapshots without changing invitation decisions.

Generator v1's PRNG, palette and drawing rules are a compatibility contract.
Do not alter v1 output in place. Add a separately versioned renderer for a future
appearance. Unsupported avatar versions are rejected rather than misrendered.

# Vanish Class Network

Flutter client for the proposed **Vanish Relay Protocol v1**. The proposal is documented in `PROTOCOL.md` and is still marked pending class agreement there.

## Relay communication

- Transport: secure WebSocket (`wss://`) with JSON text frames.
- Proposed default relay: `wss://vanish-relay-sawaira.bonto.page/ws`.
- Protocol version: `1`.
- Chat traffic uses the WebSocket relay; the legacy Field Sync HTTP endpoints are not used for chat messages.
- The app sends `join`, then waits for `welcome` before treating the connection as joined.
- The relay supplies `sent_at` and `expires_at` in milliseconds since Unix epoch. The app uses the relay clock offset and removes messages at expiry.
- Heartbeat: `ping` every 15 seconds; reconnect if no `pong` is received for 30 seconds.
- Reconnection delays: 1, 2, 4, then 8 seconds repeatedly.
- Offline queued messages are discarded if their local 30-second queue lifetime passes before they can be sent. The relay does not replay missed messages.

## Setup

From the project folder:

```bash
flutter pub get
flutter analyze
flutter test
```

## Real-device testing

1. Install and open the app on two Android devices.
2. Enter a display name (1-30 characters) on each device.
3. Confirm both devices show **Connected** after receiving `welcome` from the relay.
4. Send a message from one device and verify the other device receives it.
5. Verify the same relay-provided expiry is respected on both devices.
6. Test Wi-Fi/mobile data loss, reconnect, and the 30-second offline queue limit.

A passing unit test does not prove the hosted relay is available. Record actual JOIN/WELCOME and two-device message results separately during testing.

## Important limitations

- The protocol proposal has no password/authentication; anyone with the relay address may be able to join.
- The relay proposal says messages are held in memory only and are deleted at expiry; this client cannot independently prove the server's storage behavior.
- The protocol does not include a sender device ID in message broadcasts, so this client identifies its own echoed message by matching the outgoing message ID, not by matching display names.
- Screenshots, copying, and external recording cannot be prevented by message expiry.

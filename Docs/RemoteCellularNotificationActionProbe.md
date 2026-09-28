# Remote Cellular Notification Action Probe

## Scope

This opt-in diagnostic mode is separate from the existing `silent_background`
delivery path. A Watch request uses
`POST /v3/cellular-controls/notification-action`; the server creates the same
120-second, same-owner control and sends one visible alert to the selected
iPhone alert token. The payload contains only the fixed event plus opaque
request and account identifiers.

The notification category is `REMOTE_CELLULAR_NOTIFICATION_ACTION`. Only the
background action `START_REMOTE_CELLULAR_NOTIFICATION_ACTION` is accepted.
Opening or dismissing the notification, receiving its alert, an unknown action,
or mismatched identifiers never starts the cellular API.

After an exact action callback, the iPhone reports the distinct
`notification_action` receipt. The server remains authoritative for delivery
mode, target, owner, TTL, atomic claim, and the one-time phone-number grant. The
existing pipeline remains ordered as claim acknowledgement, start-attempt
acknowledgement, and one invocation of the public cellular starter. The
destination is transient and is not included in APNs, logs, preferences, or
diagnostic output.

`STRICT_EXPLICIT_SIM` remains the default execution mode. The separate
account-scoped `SYSTEM_MANAGED_DIAGNOSTIC` opt-in is not enabled by this push.
The system may still show a SIM picker or other confirmation.

## Limits

- APNs delivery and Watch notification forwarding are not guaranteed.
- A callback records the actual iPhone application state, but does not prove
  which physical device originated the action; origin remains `UNKNOWN`.
- `SYSTEM_START_ACCEPTED` means only that the public API accepted the request.
- This probe does not prove a connected call, zero-touch dialing, a selected
  source SIM, or carrier audio on Watch.
- Expiry without an action is `NOTIFICATION_ACTION_NOT_OBSERVED`; it is not
  proof that the alert was never delivered or that the iPhone lacked Internet.

## Future physical probe

Do not run this probe before independent source review, an explicit server
deployment decision, and a matched client release.

Conditions: keep the iPhone locked or backgrounded on an available network and
do not touch it; keep Watch on working Wi-Fi; use matching reviewed client and
server builds and an account with the required execution-mode opt-in. Create
one notification-action request from Watch, then press the forwarded Watch
notification action once.

Record outcomes separately:

- **WAKE PASS:** the iPhone action callback is actually recorded.
- **START REQUEST PASS:** the guarded public-start request is accepted; this is
  separate from a connected call.
- **ZERO-TOUCH DIAL PASS:** the verified destination actually rings without any
  action on iPhone.
- **AUDIO:** not evaluated by this experiment.

If no alert/action appears or iOS shows a SIM picker, record that exact stage.
Do not simulate an iPhone press as a Watch result or change Apple settings at
random.

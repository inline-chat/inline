# Unarchive Chat On Incoming Message

## Plan
- [x] Inspect current dialog/archive handling across server, protocol, and clients.
- [x] Add server-side unarchiveIfNeeded module and call it during message send with user-bucket persistence.
- [x] Add dialog-archive update to protos, regenerate code, and wire server sync + client update application.
- [x] Remove client-side unarchive-on-receive logic and add tests for server unarchive behavior.

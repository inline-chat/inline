# @inline/client

Goals:
- Own client-side auth state, local database cache, and realtime protocol wiring.
- Provide a small, typed API for queries/transactions and connection state.
- Offer React bindings for app integration (context + hooks).

Modules:
- `auth/`: persisted auth state + client info, emits login/logout updates.
- `database/`: in-memory object cache with query/subscription helpers.
- `realtime/`: protocol client, transport, transactions, and connection state.
- `react/`: React context + hooks for auth, db, realtime, and connection state.

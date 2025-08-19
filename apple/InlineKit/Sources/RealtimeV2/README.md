# Realtime V2

This module is responsible for:
1. Maintain connection
2. Execute transactions to mutate and fetch data
3. Sync changes on connect and in realtime

It consists of these modules:
- **Transport**: Establishes and maintains a connection to the WebSocket server 
- **Client**: Handles connect, authentication, send and receive as an abstraction of transport 
- **Sync**: Applies updates realtime and fetches missed updates when we (re)connect
- **Transactions**: Runs RPC calls with optimistic updates, retry, and error handling
- **Realtime**: The API used in application code to query, transact, and subscribe to status updates. Abstracts client, and communicates with transaction and sync submodules.


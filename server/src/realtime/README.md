# Realtime API

Goals:

- transport agnostic, we may want to support direct tcp connections in the future
- high throughput, low latency
- binary transport based on protobuf
- custom RPC system
- custom encryption and signature validation in the future

## Transport

We want to support multiple transports, for now we will only support websockets as they come with transport encryption built in.

# WiFi Secure Call

Independent iPhone and Apple Watch MVP for live Internet audio calls over HTTPS/WSS.

## Local configuration

Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and replace both values with distinct random 256-bit bearer tokens. The file is intentionally ignored by Git. Matching values are supplied to the server as protected environment variables.

The MVP protects signaling and media in transit with system TLS/WSS. It does not claim end-to-end encryption or server-blind media.


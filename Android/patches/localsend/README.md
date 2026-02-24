# Localsend-rs

A rust implementation of the [localsend protocol](https://github.com/localsend/protocol/blob/main/README.md#4-file-transfer-http-aka-upload-api) as a library.

## Completion
- [x] Fingerprinting
- [x] Discovery
  - [x] Multicast UDP
    - [x] Announce
    - [x] Listen
  - [x] HTTP register
- Upload API
  - [x] Receiving (Uploading)
    - [x] Prepare Upload
    - [x] Upload
    - [x] Cancel
  - [x] Sending
    - [x] Prepare Upload
    - [x] Upload
    - [x] Cancel
- [ ] Download API
  - [ ] Metadata
  - [ ] File
- [x] Additional
  - [x] Info
- [ ] HTTPS support

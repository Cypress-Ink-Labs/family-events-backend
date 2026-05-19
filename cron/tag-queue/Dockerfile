FROM alpine:3.20
RUN apk add --no-cache curl ca-certificates
ENTRYPOINT ["/bin/sh", "-c", "curl --fail --silent --show-error --max-time 170 -X POST -H 'Content-Type: application/json' \"$PROCESS_TAG_QUEUE_URL\" -d '{}'"]

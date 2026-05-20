FROM alpine:3.23
RUN apk add --no-cache curl ca-certificates
ENTRYPOINT ["/bin/sh", "-c", "curl --fail --silent --show-error --max-time 170 -X POST -H 'Content-Type: application/json' -H \"Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY\" \"$PROCESS_TAG_QUEUE_URL\" -d '{}'"]

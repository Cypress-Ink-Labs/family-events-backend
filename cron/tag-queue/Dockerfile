FROM alpine:3.23
RUN apk add --no-cache curl ca-certificates
COPY cron-runner.sh /usr/local/bin/cron-runner.sh
RUN chmod +x /usr/local/bin/cron-runner.sh
ENTRYPOINT ["/bin/sh", "-c", "/usr/local/bin/cron-runner.sh \"$PROCESS_TAG_QUEUE_URL\" cron-tag-queue"]

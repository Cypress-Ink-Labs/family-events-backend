FROM alpine:3.23
RUN apk add --no-cache curl ca-certificates
COPY cron-runner.sh /usr/local/bin/cron-runner.sh
RUN chmod +x /usr/local/bin/cron-runner.sh
ENTRYPOINT ["/bin/sh", "-c", "/usr/local/bin/cron-runner.sh \"$CLEANUP_STALE_RUNS_URL\" cron-cleanup-stale"]

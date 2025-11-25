FROM alpine

COPY ok /ok

CMD echo "healthy 2" && sleep infinity

HEALTHCHECK --interval=2s --timeout=1s --start-period=1s --retries=1 CMD /ok

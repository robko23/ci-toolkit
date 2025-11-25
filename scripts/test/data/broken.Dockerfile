FROM alpine

COPY fail /fail

CMD ["sleep", "infinity"]

HEALTHCHECK --interval=2s --timeout=1s --start-period=1s --retries=1 CMD /fail

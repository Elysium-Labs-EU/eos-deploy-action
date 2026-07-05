FROM alpine:3.21

RUN apk add --no-cache openssh-client bash

COPY scripts/deploy.sh /deploy.sh
RUN chmod +x /deploy.sh

ENTRYPOINT ["/deploy.sh"]

FROM alpine:3.21

RUN apk add --no-cache curl jq

COPY seed.sh /usr/local/bin/metio-zabbix-bootstrap

RUN chmod 0755 /usr/local/bin/metio-zabbix-bootstrap

ENTRYPOINT ["/usr/local/bin/metio-zabbix-bootstrap"]

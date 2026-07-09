#!/bin/sh
# DuckDNS updater — keeps <SUBDOMAIN>.duckdns.org pointed at the current public IP.
#
# Install on the router:
#   cp ddns-update.sh /etc/ddns-update.sh
#   chmod +x /etc/ddns-update.sh
#   echo "*/5 * * * * /etc/ddns-update.sh" >> /etc/crontabs/root
#   service cron enable && service cron start
#
# Test:
#   sh /etc/ddns-update.sh && cat /tmp/duckdns.log   # must print OK
#
# Leaving ip= empty lets DuckDNS auto-detect the source IP of the request.

DOMAIN="YOUR_SUBDOMAIN"     # subdomain only, without .duckdns.org
TOKEN="YOUR_TOKEN"          # from your duckdns.org account page

curl -s "https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=" -o /tmp/duckdns.log

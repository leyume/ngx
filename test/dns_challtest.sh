#!/usr/bin/env sh
# test-only acme.sh DNS hook: writes TXT records into pebble-challtestsrv's mock DNS
dns_challtest_add() { curl -s -d "{\"host\":\"$1.\",\"value\":\"$2\"}" http://challtestsrv:8055/set-txt; }
dns_challtest_rm()  { curl -s -d "{\"host\":\"$1.\"}" http://challtestsrv:8055/clear-txt; }

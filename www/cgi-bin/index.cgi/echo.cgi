echo "Content-Type: application/json"; echo ""
ts="$(date '+%F %T')"; qs="${QUERY_STRING:-}"
echo "{\"ok\":true,\"ts\":\"$ts\",\"qs\":\"$qs\"}"
echo "$ts QS=$qs" >> /tmp/mqtt-echo.log

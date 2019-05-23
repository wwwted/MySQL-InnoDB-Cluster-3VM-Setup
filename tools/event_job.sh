#!/bin/bash
#
# Handles simple use case of enable/disable events and event handler when using
# InnoDB Cluster. Only enable events on PRIMARY node.
#
# Works like:
#  if (primary)
#      if (event scheduler is disabled) -- means, we have had a failover/switchover
#          enable all events ()
#          enable event scheduler ()
#  else  -- secondary
#      if (event scheduler enabled)
#          disable event scheduler ()
#
# Run via crontab on MySQL nodes
#
# USE AT OWN RISK!!
#
# TODO:
# - Login using login-path to avoid warnings: https://dev.mysql.com/doc/refman/8.0/en/mysql-config-editor.html
# - Add lock via table/row in DB to avoid multiple instances running at the same time
#   Not sure how important this is, should be safe as it is ....
# - Remove use of temporary file /tmp/events.tmp
#

MyHosts=("127.0.0.1:3310" "127.0.0.1:3320" "127.0.0.1:3330")
dbUser="root"
dbPwd="root"
debug=0

for val in ${MyHosts[*]}; do
     host=`echo $val|cut -d: -f1`
     port=`echo $val|cut -d: -f2`
     if [ $debug -gt 0 ]; then echo "Server: $host $port"; fi
     server_uuid=`mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SELECT @@server_UUID"`
     primary_uuid=`mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY'"`
     event_scheduler_status=`mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='event_scheduler'"`

     if [ -z "$server_uuid" ]
     then
        echo "Did not find any server_uuid for ($host,$port), exiting..."
        exit 1
     fi
     if [ $debug -gt 0 ]; then echo $server_uuid $primary_uuid $event_scheduler_status; fi

     if [ "$server_uuid" = "$primary_uuid" ]
     then
        if [ $debug -gt 0 ]; then echo "Primary"; fi
        if [ "$event_scheduler_status" = "OFF" ]
        then
           echo "PRIMARY($host:$port): Enable all the events and start event scheduler"
           mysql mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SELECT CONCAT('ALTER EVENT ',EVENT_SCHEMA,'.',EVENT_NAME,' ENABLE;') FROM INFORMATION_SCHEMA.EVENTS WHERE STATUS != 'ENABLED'" > /tmp/events.tmp
           mysql mysql -u$dbUser -p$dbPwd -h$host -P$port < /tmp/events.tmp
           mysql mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SET GLOBAL event_scheduler = ON"
           mysql mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SET PERSIST event_scheduler = ON"
        fi
     else # slave/secondary
        if [ $debug -gt 0 ]; then echo "Secondary"; fi
        if [ "$event_scheduler_status" = "ON" ]
        then
           echo "SECONDARY($host:$port): Disable the event scheduler"
           mysql mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SET GLOBAL event_scheduler = OFF"
           mysql mysql -u$dbUser -p$dbPwd -h$host -P$port -se"SET PERSIST event_scheduler = OFF"
        fi
     fi
done


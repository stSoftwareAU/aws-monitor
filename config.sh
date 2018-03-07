#!/bin/bash
set -e
AUTO_SCALE=$1
LAUNCH_CONFIG=$1

while [ 1 ]
do
    action=`curl http://169.254.169.254/latest/meta-data/instance-action`

    echo $action
    if [ "$action" != "none" ]
    then
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name $AUTO_SCALE --launch-configuration-name $LAUNCH_CONFIG
    fi
    sleep 5
done

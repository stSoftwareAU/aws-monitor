#!/bin/bash
set -e

for asName in "$@"
do
    if [[ "$asName" =~ http(s|)://.+ ]]; then
        json=$(curl --silent --fail -X PUT $asName ) 
    else
        json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name $asName )

        launchConfigurationName=$( jq -r '.AutoScalingGroups[0].LaunchConfigurationName'<<<${json} )

        minSize=$( jq -r '.AutoScalingGroups[0].MinSize'<<<${json} )

        if [[ $minSize > 1 ]]; then

            count=$( jq -r '.AutoScalingGroups[0].Instances|length'<<<${json} )

            if [[ $launchConfigurationName =~ .+#spot_.+ ]]; then 
                if [[ $count < 2 ]]; then
                    costlyConfigurationName="${launchConfigurationName/\#spot_/\#costly_}"
                    echo "Only $count of $minSize running, changing launch configuration to: $costlyConfigurationName"
                    aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $costlyConfigurationName
                elif [[ $count = $minSize ]]; then 
                    if [[ $minSize >2 ]]; then
                        echo "Scale up target reached, reset min $minSize -> 2"
                        aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --min-size 2
                    fi
                fi
            elif [[ $launchConfigurationName =~ .+#costly_.+ ]]; then
                desiredCapacity=$( jq -r '.AutoScalingGroups[0].DesiredCapacity'<<<${json} )
                if [[ $count = $desiredCapacity ]]; then
                    increaseCapacity=$(($minSize + 2))
                    if [[ $desiredCapacity < $increaseCapacity ]]; then
                        spotConfigurationName="${launchConfigurationName/\#costly_/\#spot_}"
                        echo "Changing to cheaper launch configuration: $spotConfigurationName"

                        aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $spotConfigurationName --desired-capacity $increaseCapacity --min-size $increaseCapacity
                    fi
                fi
            else
                echo "Not a valid launch configuration name: $launchConfigurationName"
            fi
        fi
     fi
done

#!/bin/bash
set -e

for asName in "$@"
do
    if [[ "$asName" =~ http(s|)://.+ ]]; then
        json=$(curl --silent --fail -X PUT $asName ) 
    else
        json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name $asName )
        
        total=$( jq -r '.AutoScalingGroups[0].Instances|length'<<<${json} )
        if [[ ${total} > 0 ]]; then
          count=1
          echo $json| jq -c '.AutoScalingGroups[0].Instances[]' | while read instanceJSON; do
            instanceID=$(jq -r ".InstanceId" <<< $instanceJSON)

            aws ec2 create-tags --resources $instanceID --tag Key=Name,Value="$asName#$count"
            count=$((count+1))
          done
        fi

        launchConfigurationName=$( jq -r '.AutoScalingGroups[0].LaunchConfigurationName'<<<${json} )

        if [ ! -z $launchConfigurationName ] && [ "$launchConfigurationName" != "null" ]; then
            minSize=$( jq -r '.AutoScalingGroups[0].MinSize'<<<${json} )

            if [[ $minSize > 1 ]]; then

                if [[ $launchConfigurationName =~ .+#spot_.+ ]]; then 
                    if [[ $total < 2 ]]; then
                        costlyConfigurationName="${launchConfigurationName/\#spot_/\#costly_}"
                        echo "Only $total of $minSize running, changing launch configuration to: $costlyConfigurationName"
                        aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $costlyConfigurationName
                    elif [[ $total = $minSize ]]; then 
                        if [[ $minSize >2 ]]; then
                            echo "Scale up target reached, reset min $minSize -> 2"
                            aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --min-size 2
                        fi
                    fi
                elif [[ $launchConfigurationName =~ .+#costly_.+ ]]; then
                    desiredCapacity=$( jq -r '.AutoScalingGroups[0].DesiredCapacity'<<<${json} )
                    if [[ $total = $desiredCapacity ]]; then
                        increaseCapacity=$(($minSize + 2))
                        if [[ $desiredCapacity < $increaseCapacity ]]; then
                            spotConfigurationName="${launchConfigurationName/\#costly_/\#spot_}"
                            echo "Changing to cheaper launch configuration: $spotConfigurationName"

                            aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $spotConfigurationName --desired-capacity $increaseCapacity --min
    -size $increaseCapacity
                        fi
                    fi
                else
                    echo "Not a valid launch configuration name: $launchConfigurationName"
                fi
            fi
         fi
    fi
done

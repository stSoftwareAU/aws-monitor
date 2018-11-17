#!/bin/bash
set -e

DIR="$( cd -P "$( dirname "$BASH_SOURCE" )" && pwd -P )"
cd $DIR

./checkSpotRequests.sh

for asName in "$@"
do
    if [[ "$asName" =~ http(s|)://.+ ]]; then
        json=$(curl --silent --fail -X PUT $asName ) 
    else
        json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name $asName )
        
#        rm -f ~/${asName}_costly

        instanceCount=$( jq -r '.AutoScalingGroups[0].Instances|length'<<<${json} )
        if [[ ${instanceCount} > 0 ]]; then
          count=1
          echo $json| jq -c '.AutoScalingGroups[0].Instances[]' | while read instanceJSON; do
            instanceID=$(jq -r ".InstanceId" <<< $instanceJSON)

            instanceDescribeJSON=$(aws ec2 describe-instances --instance-ids $instanceID)
            currentName=$(jq -r '.Reservations[0].Instances[0].Tags|try map( select( .Key == "Name")) catch []|.[0].Value'<<<$instanceDescribeJSON)
            newName=$asName#$count
            if [ "$currentName" != "$newName" ]; then
               echo "$currentName -> $newName"
               aws ec2 create-tags --resources $instanceID --tag Key=Name,Value="$newName"
            fi
            count=$((count+1))

#            healthStatus=$(jq -r ".HealthStatus" <<< $instanceJSON)
#            if [[ $healthStatus = 'Healthy' ]]; then
#                lifecycleState=$(jq -r ".LifecycleState" <<< $instanceJSON)
#                if [[ $lifecycleState = 'InService' ]]; then
#                  launchConfigurationName=$(jq -r ".LaunchConfigurationName" <<< $instanceJSON)
#
#                  if [[ $launchConfigurationName =~ .+#costly_.+ ]]; then
#                    touch ~/${asName}_costly
#                  fi
#                fi
#            fi
          done
        fi

        launchConfigurationName=$( jq -r '.AutoScalingGroups[0].LaunchConfigurationName'<<<${json} )

        if [ ! -z $launchConfigurationName ] && [ "$launchConfigurationName" != "null" ]; then
            minSize=$( jq -r '.AutoScalingGroups[0].MinSize'<<<${json} )
            
            if [[ $instanceCount < $minSize ]]; then
                if [[ $launchConfigurationName =~ .+#spot_.+ ]]; then 
                    minRunning=$(($minSize -2 ));
                    if [[ $minRunning < 1 ]]; then
                       minRunning=1;
                    fi
                    if [[ $instanceCount < $minRunning ]]; then
                        costlyConfigurationName="${launchConfigurationName/\#spot_/#costly_}"
                        echo "Only $instanceCount of $minSize running, changing launch configuration to: $costlyConfigurationName"
                        aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $costlyConfigurationName
                    fi
                fi
            #elif [[ $minSize > 0 && $instanceCount -ge $minSize && -f ~/${asName}_costly ]]; then
            #    spotConfigurationName="${launchConfigurationName/\#costly_/#spot_}";
            #    if [[ "$launchConfigurationName" != "$spotConfigurationName" ]]; then
            #        echo "$costCount costly instances running, changing launch configuration to: $spotConfigurationName"
            #        aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $spotConfigurationName

            #        maxSize=$( jq -r '.AutoScalingGroups[0].MaxSize'<<<${json} );
            #        increaseCapacity=$(($minSize + 2))
            #        if [[ $increaseCapacity > $maxSize ]]; then
            #            increaseCapacity=$maxSize;
            #        fi

            #        desiredCapacity=$( jq -r '.AutoScalingGroups[0].DesiredCapacity'<<<${json} )
            #        if [[ $desiredCapacity < $increaseCapacity ]]; then
            #            echo "Increasing DesiredCapacity from $desiredCapacity -> $increaseCapacity for $asName as costly instances running."
            #            aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --desired-capacity $increaseCapacity
            #        fi
            #    fi
            fi
         fi
    fi
done

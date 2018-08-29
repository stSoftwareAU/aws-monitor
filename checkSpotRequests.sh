#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

function switchToCostly {
    asName=$1

    local asJSON=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name $asName )
    launchConfigurationName=$( jq -r '.AutoScalingGroups[0].LaunchConfigurationName'<<<${asJSON} )

    if [ ! -z $launchConfigurationName ] && [ "$launchConfigurationName" != "null" ]; then
       local costlyConfigurationName="${launchConfigurationName/\#spot_/#costly_}"
       aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asName --launch-configuration-name $costlyConfigurationName
    fi
}

function main {

  requestsJSON=$(aws ec2  describe-spot-instance-requests)

  local noCapcityArray=$(jq --compact-output --raw-output '.SpotInstanceRequests|map( select( .Status.Code == "capacity-not-available"))' <<< ${requestsJSON})
#  (>&2 jq . <<< ${noCapcityArray} )

  local cancelledList=$(jq --raw-output '.[].SpotInstanceRequestId' <<< ${noCapcityArray})

  for spotID in ${cancelledList}; do
    set +e
    local spotJSON=$(aws ec2  describe-spot-instance-requests --spot-instance-request-ids ${spotID} )
    local imageId=$(jq --raw-output '.SpotInstanceRequests[0].LaunchSpecification.ImageId' <<< ${spotJSON})
    local imageJSON=$(aws ec2 describe-images --image-ids ${imageId})

    local imageName=$(jq --raw-output '.Images[0].Name' <<< ${imageJSON})
    webName=`echo ${imageName//_[0-9]*/}`-web
    switchToCostly $webName
    batchName=`echo ${imageName//_[0-9]*/}`-batch
    switchToCostly $batchName

    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids ${spotID}
  done

  echo ${cancelledList}
}

main "$@"

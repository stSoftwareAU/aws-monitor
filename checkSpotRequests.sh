#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

function main {

  requestsJSON=$(aws ec2  describe-spot-instance-requests)

  #(>&2 jq . <<< $requestsJSON )

  local noCapcityArray=$(jq --compact-output --raw-output '.SpotInstanceRequests|map( select( .Status.Code == "capacity-not-available"))' <<< ${requestsJSON})
  (>&2 jq . <<< ${noCapcityArray} )

  local cancelledList=$(jq --raw-output '.[].SpotInstanceRequestId' <<< ${noCapcityArray})

  for spotID in ${cancelledList}; do

    aws ec2 cancel-spot-instance-requests --spot-instance-request-ids ${spotID}
  done

  echo ${cancelledList}
}

main "$@"


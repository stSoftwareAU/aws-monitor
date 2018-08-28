#!/usr/bin/env bash
# Configures aws auto scaling groups
# Input: json file 	 <<<KEEP THIS UP TO DATE>>>
#{
#	"AutoScalingGroupName" : "<name>",
#	"CostModel" : "<spot or costly>",
#	"InstanceType" : "<size of machine ie 2X>",
#	"MinSize" : "<min #instances>",
#	"MaxSize" : "<max #instances>",
#	"DesiredCapacity" : "<desired #instances>"
#   "_pause": number of seconds
#   "_deploy": true to start a rolling deploy.
#}	
# Note: Only AutoScalingGroupName is mandatory, though InstanceType and MachineSize should always be included when relevent. 

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace
DIR="$( cd -P "$( dirname "$BASH_SOURCE" )" && pwd -P )"
cd $DIR

main() {
    #Variable declaration (all omitted variables are made empty)
    config_array_file="$1"

    local configArray=$(jq -c '.[]' ${config_array_file})

    for configJson in $configArray; do

        auto_scaling_group_name=$(jq -r '.AutoScalingGroupName // empty' <<<"${configJson}")
        cost_model=$(jq -r '.CostModel // empty' <<<"${configJson}")
        instance_type=$(jq -r '.InstanceType // empty' <<<"${configJson}")
        min_size=$(jq -r '.MinSize // empty' <<<"${configJson}")
        desired_capacity=$(jq -r '.DesiredCapacity // empty' <<<"${configJson}")
        max_size=$(jq -r '.MaxSize // empty' <<<"${configJson}")

        pause=$(jq -r '.pause // empty' <<<"${configJson}")

        if [[ ! -z "${pause}" ]]; then
           echo "sleeping ${pause}..."
           sleep ${pause}
        fi
        # Find launch configuration ID
        auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
        old_launch_config=$(jq -r '.AutoScalingGroups[].LaunchConfigurationName'<<<"${auto_scaling_group_json}")
        ID="${old_launch_config/*_}"

        # Construct new launch configuration name
        launch_config_name="${auto_scaling_group_name}"
        [ ! -z "${instance_type}" ] && launch_config_name="${launch_config_name}@${instance_type}"
        [ ! -z "${cost_model}" ] && launch_config_name="${launch_config_name}#${cost_model}"
        launch_config_name="${launch_config_name}_${ID}"

        # Construct JSON object for new auto scaling group configuration
        if [[ -z "${instance_type}" ]] && [[ -z "${cost_model}" ]]; then
          cli_input_json="{}"
        else
          cli_input_json=$(jq -n --arg lcn "${launch_config_name}" '{"LaunchConfigurationName": $lcn}')
        fi
        [ ! -z "${min_size}" ] &&  cli_input_json=$(jq --argjson ms "${min_size}" '.+{"MinSize": $ms}'<<<"${cli_input_json}")
        [ ! -z "${desired_capacity}" ] &&  cli_input_json=$(jq --argjson dc "${desired_capacity}" '.+{"DesiredCapacity": $dc}'<<<"${cli_input_json}")
        [ ! -z "${max_size}" ] &&  cli_input_json=$(jq --argjson ms "${max_size}" '.+{"MaxSize": $ms}'<<<"${cli_input_json}")

        # Update auto scaling group configuration
        jsonFile=$(mktemp /tmp/aws.XXXXXX.json)
        echo "${cli_input_json}" > $jsonFile
        # (>&2 jq . $jsonFile) 
        aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --cli-input-json file://${jsonFile}
        rm $jsonFile
    done
}

main "$@"

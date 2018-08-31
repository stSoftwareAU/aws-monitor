#!/usr/bin/env bash
# Details <<<KEEP THESE UP TO DATE>>>
# Script: kissRollingDeploy.sh
# Function: Safely enforces an auto scaling group's launch configuration in a super simple way
# Input: the auto scaling group's name, and an optional parameter minutes to wait between scaling. 

set -o errexit
set -o pipefail
set -o nounset
#set -o xtrace # Uncomment to debug

# Parameters
declare -i minutes=${2:-15} 				# default 15 minutes
declare -i scale_in_rest_period=$((60 * minutes))   	# minutes
declare -i scale_out_rest_period=$((60 * minutes))  	# minutes

#Global declared variables
declare -r auto_scaling_group_name="$1"

main() {
	# Variables 
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
	if [ $(jq -r '.AutoScalingGroups | length'<<<"${auto_scaling_group_json}") != 1 ]; then
		 &>2 echo "There is not one unique auto scaling group by the name of ${auto_scaling_group_name}"
		 exit 1 
	fi
	launch_configuration_name=$(jq -r '.AutoScalingGroups[].LaunchConfigurationName'<<<"${auto_scaling_group_json}")
	min_size=$(jq -r '.AutoScalingGroups[].MinSize'<<<"${auto_scaling_group_json}")
	max_size=$(jq -r '.AutoScalingGroups[].MaxSize'<<<"${auto_scaling_group_json}")
	if [ $min_size -eq $max_size ]; then
		&>2 echo "${auto_scaling_group_name} is configured with min-size = max-size"
		exit 1
	fi

	
	# Rolling deploy 
	if satisfied; then 
		echo "auto scaling group ${auto_scaling_group_name} already compliant"
	else 
		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --termination-policies "OldestInstance" "Default"
		
		# set min to the current number of healty machines + number of new machines needed, if it does not exceed the maximum. 
		count_number_of_new_machines_needed
		number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
                	<<<"${auto_scaling_group_json}")
		declare -i new_min=$((number_healthy + number_of_new_machines_needed < max_size ? number_healthy + number_of_new_machines_needed: max_size))
		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $new_min

		sleep $scale_in_rest_period

		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $min_size --desired-capacity $min_size

		sleep $scale_out_rest_period
	fi
	
	# Reset launch config, min, and desired.
	aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" \
		--min-size $min_size --desired-capacity $min_size \
		--termination-policies "OldestLaunchConfiguration" "OldestInstance" "Default"
	
	# Confirm successful deploy
	if ! satisfied; then
		&>2 echo "Rolling deploy failed for ${auto_scaling_group_name}"
		exit 1
	fi
}

# Checks the launch configuration is satisfied
satisfied() {
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
	number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
		<<<"${auto_scaling_group_json}")
	if [[ "${launch_configuration_name}" =~ .*#costly[^a-z,0-9].* ]]; then	
		local number_healthy_and_correct=$(jq --arg lcn1 "${launch_configuration_name}" --arg lcn2 "${launch_configuration_name//\#costly/\#spot}" \
        	        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and
	                (.LaunchConfigurationName==$lcn1 or .LaunchConfigurationName==$lcn2))] | length' <<< "${auto_scaling_group_json}")
	else     
		local number_healthy_and_correct=$(jq --arg lcn "${launch_configuration_name}" \
			'[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and .LaunchConfigurationName==$lcn)] | length' \
			<<< "${auto_scaling_group_json}")
	fi
	if [ "${number_healthy}" -ge "${min_size}" ] && [ "${number_healthy}" -eq "${number_healthy_and_correct}" ]; then
		true; return
	else
		false; return
	fi
}

count_number_of_new_machines_needed() {
        if [[ "${launch_configuration_name}" =~ .*#costly[^a-z,0-9].* ]]; then
                local number_healthy_and_correct=$(jq --arg lcn1 "${launch_configuration_name}" --arg lcn2 "${launch_configuration_name//\#costly/\#spot}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and
                        (.LaunchConfigurationName==$lcn1 or .LaunchConfigurationName==$lcn2))] | length' <<< "${auto_scaling_group_json}")
        else
                local number_healthy_and_correct=$(jq --arg lcn "${launch_configuration_name}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService" and .LaunchConfigurationName==$lcn)] | length' \
                        <<< "${auto_scaling_group_json}")
        fi
	
	number_of_new_machines_needed=$((min_size - number_healthy_and_correct))
	if [ $number_of_new_machines_needed -lt 0 ]; then
                 number_of_new_machines_needed=0
        fi
}

main "$@"

#!/usr/bin/env bash
# Details <<<KEEP THESE UP TO DATE>>>
# Script: RollingDeploy.sh
# Function: Safely enforces an auto scaling group's launch configuration
# Input: the auto scaling group's name

set -o errexit
set -o pipefail
set -o nounset
#set -o xtrace # Uncomment to debug

# Parameters
declare -i tolerance=60*15	 	# minutes
declare -i scale_in_rest_period=60 	# seconds
declare -i scale_out_rest_period=120	# seconds
declare -i monitoring_rest_period=10	# seconds

# Global declared variables
declare -i t0=$(date +%s)		#start the clock
declare -i time=$(($(date +%s) - t0))
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
	desired_capacity=$(jq -r '.AutoScalingGroups[].DesiredCapacity'<<<"${auto_scaling_group_json}")
	
	# Rolling deploy 
	if satisfied; then 
		echo "auto scaling group ${auto_scaling_group_name} already compliant"
	else 
		# Set termination policies 
		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --termination-policies "OldestInstance" "Default"
			
		while ! satisfied && [ $time -lt $tolerance ]; do
			
			# TODO increase min by number of wrong instances
			declare -i new_min=$((desired_capacity + 1 < max_size ? desired_capacity + 1: max_size))
			aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $new_min
			
			sleep $scale_in_rest_period
			time=$(($(date +%s) - t0))
			monitor_until_stable

			aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $min_size --desired-capacity $min_size

			sleep $scale_out_rest_period
			time=$(($(date +%s) - t0))
			monitor_until_stable

			# Update variables
			auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
			launch_configuration_name=$(jq -r '.AutoScalingGroups[].LaunchConfigurationName'<<<"${auto_scaling_group_json}")
			time=$(($(date +%s) - t0))
		done
	fi
	
	# Reset launch config, min, max, and desired.
	aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" \
		--min-size $min_size --max-size $max_size --desired-capacity $min_size \
		--termination-policies "OldestLaunchConfiguration" "OldestInstance" "Default"
	
	# Confirm successful deploy
	if ! satisfied; then
		&>2 echo "Rolling deploy failed for ${auto_scaling_group_name}"
		exit 1
	fi
}

# Checks the launch configuration is satisfied
satisfied() {
	local number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
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

# Checks the system is stable
stable() {
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
	local number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
		<<<"${auto_scaling_group_json}")
	local number_instances=$(jq '[.AutoScalingGroups[].Instances[] | select(.LifecycleState!="Terminating")] | length'<<<"${auto_scaling_group_json}")

	if [ ${number_instances} -eq ${number_healthy} ]; then
		true; return
	else
		false; return
	fi  
}

# Waits for the system to be stable before moving on
monitor_until_stable() {
        while  ! stable  && [ $time -lt $tolerance ]; do
        	sleep $monitoring_rest_period
                time=$(($(date +%s) - t0))
        done
}

# set number_healthy by counting the number of healthy instnaces in the autoscaling group.
#TODO set number_healthy to global variable
count_healthy_instances() {
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
	health_check_type=$(jq '.AutoScalingGroups[].HealthCheckType'<<<"${auto_scaling_group_json}")
	if [ "$health_check_type" = "EC2" ]; then
		number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length' \
			<<<"${auto_scaling_group_json}")
	elif[ "$health_check_type" = "ELB" ]; then
		#TODO get health status from ELB
	else
		 &>2 echo "${auto_scaling_group_name} has unhandled health check type"
}

main "$@"

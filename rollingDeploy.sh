#!/usr/bin/env bash
# Details <<<KEEP THESE UP TO DATE>>>
# Script: RollingDeploy.sh
# Function: Safely enforces an auto scaling group's launch configuration
# Input: the auto scaling group's name

set -o errexit
set -o pipefail
set -o nounset
#set -o xtrace # Uncomment to debug

main() {
	# Parameters
	declare -i tolerance=1200 	# 20 minutes
	declare -i rest_period=65	# 65 seconds

	# Variables 
	auto_scaling_group_name="$1"
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
	if [ $(jq -r '.AutoScalingGroups | length'<<<"${auto_scaling_group_json}") != 1 ]; then
		 echo "there is not one unique auto scaling group by that name"
		 exit 1 
	fi
	launch_configuration_name=$(jq -r '.AutoScalingGroups[].LaunchConfigurationName'<<<"${auto_scaling_group_json}")
	min_size=$(jq -r '.AutoScalingGroups[].MinSize'<<<"${auto_scaling_group_json}")
	number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy")] | length'<<<"${auto_scaling_group_json}")		
	max_size=$(jq -r '.AutoScalingGroups[].MaxSize'<<<"${auto_scaling_group_json}")
	desired_capacity=$(jq -r '.AutoScalingGroups[].DesiredCapacity'<<<"${auto_scaling_group_json}")
	health_check_type=$(jq -r '.AutoScalingGroups[].HealthCheckType'<<<"${auto_scaling_group_json}")	
	
	#Rolling deploy 
	if satisfied; then 
		echo "auto scaling group ${auto_scaling_group_name} already compliant"
	else
		# More variables
		declare -i t0=$(date +%s)	#start the clock
		declare -i t1=$t0
		target_groups_json=`aws autoscaling describe-load-balancer-target-groups --auto-scaling-group-name "${auto_scaling_group_name}"`
                target_groups=$(jq -r '.LoadBalancerTargetGroups[] | .LoadBalancerTargetGroupARN'<<<"${target_groups_json}")	

		#Rock and roll
		while ! satisfied && [ $((t1 - t0)) -lt $tolerance ]; do
			
			if [ ${number_healthy} -gt 1 ]; then 
				$(silently_kill_instance) 
				t1=$(date +%s)				

				#wait for the dust to settle
				while  ! stable  && [ $((t1 - t0)) -lt $tolerance ]; do
					sleep $rest_period
					t1=$(date +%s)
                       		done
				
				aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $min_size

			elif [ ${min_size} -le 1 ]; then
				aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size 2
				
				#wait for the dust to settle
				while ! stable && [ $((t1 - t0)) -lt $tolerance ]; do
					sleep  $rest_period
					t1=$(date +%s)
				done
				
				aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $min_size
			fi

			#wait for the dust to settle
			sleep $rest_period
			t1=$(date +%s)

			while ! stable && [ $((t1 - t0)) -lt $tolerance ]; do
				sleep  $rest_period
				t1=$(date +%s)
			done
			
			# Update variables
			auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
			number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy")] | length'<<<"${auto_scaling_group_json}")
			t1=$(date +%s)
		done
	fi
	
	#Confirm successful deploy
	if ! satisfied; then
		exit 1
	fi
}

satisfied() {
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
        number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy")] | length'<<<"${auto_scaling_group_json}")
	local number_healthy_and_correct=$(jq --arg lcn "${launch_configuration_name}" \
                        '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LaunchConfigurationName==$lcn)] | length' \
                        <<< "${auto_scaling_group_json}")

	if [ "${number_healthy}" -ge "${min_size}" ] && [ "${number_healthy}" -eq "${number_healthy_and_correct}" ]; then
		true; return
	else
		false; return
	fi
}

# Safely take an instance out of servic, or failing that, increase min and desired capacity.
silently_kill_instance() {
	
	desired_capacity=$(jq -r '.AutoScalingGroups[].DesiredCapacity'<<<"${auto_scaling_group_json}")
	
	if [ "${health_check_type}" = "ELB" ]; then
		local victum_id=$(jq --arg lcn "${launch_configuration_name}" \
			'[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LaunchConfigurationName!=$lcn)][0] | .InstanceId' \
			<<< "${auto_scaling_group_json}")

        	for target_group_arn in "${target_groups}"; do
                	aws elbv2 deregister-targets --target-group-arn "${target_group_arn}" --targets Id="${victum_id}"
	        done
	else 
		local new_min=$((desired_capacity + 1 < max_size ? desired_capacity + 1: max_size))
		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${auto_scaling_group_name}" --min-size $new_min
	fi
	
	sleep $rest_period

}

stable() {
	auto_scaling_group_json=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${auto_scaling_group_name}")
	number_healthy=$(jq '[.AutoScalingGroups[].Instances[] | select(.HealthStatus=="Healthy" and .LifecycleState=="InService")] | length'<<<"${auto_scaling_group_json}")
	number_instances=$(jq '[.AutoScalingGroups[].Instances[] | select(.LifecycleState!="Terminating")] | length'<<<"${auto_scaling_group_json}")
	if [ ${number_instances} -eq ${number_healthy} ]; then
		true; return
	else
		false; return
	fi  
}

main "$@"
